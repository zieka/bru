const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const Index = @import("../index.zig").Index;
const IndexEntry = @import("../index.zig").IndexEntry;
const cask_index_mod = @import("../cask_index.zig");
const CaskIndex = cask_index_mod.CaskIndex;
const CaskIndexEntry = cask_index_mod.CaskIndexEntry;
const HttpClient = @import("../http.zig").HttpClient;
const Output = @import("../output.zig").Output;
const fuzzy = @import("../fuzzy.zig");

/// Show the git log for a formula or cask, or the Homebrew repository.
///
/// Usage: bru log [options] [formula|cask]
///
/// If no formula or cask is given, shows the log for the Homebrew repository.
/// Otherwise, looks up the formula/cask and shows the log for its source file.
pub fn logCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    var formula_name: ?[]const u8 = null;
    var force_formula = false;
    var force_cask = false;

    // Collect git flags (everything except --formula/--cask and the positional name).
    // Flags like -n and --max-count consume the next argument as their value.
    var git_flags = std.ArrayList([]const u8){};
    defer git_flags.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--formula") or std.mem.eql(u8, arg, "--formulae")) {
            force_formula = true;
        } else if (std.mem.eql(u8, arg, "--cask") or std.mem.eql(u8, arg, "--casks")) {
            force_cask = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--max-count")) {
            // -n and --max-count consume the next arg as their value.
            try git_flags.append(allocator, arg);
            if (i + 1 < args.len) {
                i += 1;
                try git_flags.append(allocator, args[i]);
            }
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try git_flags.append(allocator, arg);
        } else {
            if (formula_name == null) formula_name = arg;
        }
    }

    const git_flag_slice = git_flags.items;

    // No formula/cask name: show log for the whole Homebrew repository.
    if (formula_name == null) {
        execGitLog(allocator, config.repository, git_flag_slice, null);
    }

    const the_name = formula_name.?;

    // Try formula index first (unless --cask was specified).
    if (!force_cask) {
        if (tryFormulaLog(allocator, the_name, git_flag_slice, config)) return;
    }

    // Try cask index (unless --formula was specified).
    if (!force_formula) {
        if (tryCaskLog(allocator, the_name, git_flag_slice, config)) return;
    }

    // Nothing found: error with suggestions.
    var idx = Index.loadOrBuild(allocator, config.cache) catch {
        const err_out = Output.initErr(config.no_color);
        err_out.err("No available formula or cask with the name \"{s}\".", .{the_name});
        std.process.exit(1);
    };

    const err_out = Output.initErr(config.no_color);
    err_out.err("No available formula or cask with the name \"{s}\".", .{the_name});
    err_out.print("Searched: {s}/api/formula.jws.json\n", .{config.cache});
    const similar = fuzzy.findSimilar(&idx, allocator, the_name, 3, 3) catch &.{};
    defer if (similar.len > 0) allocator.free(similar);
    if (similar.len > 0) {
        err_out.print("Did you mean?\n", .{});
        for (similar) |s| err_out.print("  {s}\n", .{s});
    }
    std.process.exit(1);
}

/// Replace the current process with `git -C {repo} log [flags...] [-- file]`.
/// This function never returns on success (execve replaces the process).
pub fn execGitLog(allocator: Allocator, repo_path: []const u8, git_flags: []const []const u8, file_path: ?[]const u8) noreturn {
    // argv: "git" "-C" repo "log" [flags...] ["--" file]
    const has_file: usize = if (file_path != null) 2 else 0;
    const argv_len = 4 + git_flags.len + has_file;
    const argv = allocator.alloc([]const u8, argv_len) catch {
        printStderr("bru: error: out of memory\n");
        std.process.exit(1);
    };

    argv[0] = "git";
    argv[1] = "-C";
    argv[2] = repo_path;
    argv[3] = "log";
    if (git_flags.len > 0) {
        @memcpy(argv[4 .. 4 + git_flags.len], git_flags);
    }
    if (file_path) |fp| {
        argv[argv_len - 2] = "--";
        argv[argv_len - 1] = fp;
    }

    const err = std.process.execve(allocator, argv, null);

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    stderr.print("bru: error: failed to exec git: {}\n", .{err}) catch {};
    stderr.flush() catch {};
    std.process.exit(1);
}

/// Try to show the log for a formula. Returns true if the formula was found
/// and the log was shown (or execGitLog was called, which does not return).
fn tryFormulaLog(allocator: Allocator, name: []const u8, git_flags: []const []const u8, config: Config) bool {
    var idx = Index.loadOrBuild(allocator, config.cache) catch return false;
    const entry = idx.lookup(name) orelse return false;
    const tap = idx.getString(entry.tap_offset);
    const formula_name = idx.getString(entry.name_offset);
    if (tap.len == 0) return false;

    const slash = std.mem.indexOfScalar(u8, tap, '/') orelse return false;
    if (slash == 0 or slash + 1 >= tap.len) return false;
    const org = tap[0..slash];
    const repo = tap[slash + 1 ..];

    // Build tap path: {repository}/Library/Taps/{org}/homebrew-{repo}
    var tap_path_buf: [1024]u8 = undefined;
    const tap_path = std.fmt.bufPrint(&tap_path_buf, "{s}/Library/Taps/{s}/homebrew-{s}", .{ config.repository, org, repo }) catch return false;

    // Build formula file path using the canonical name from the index.
    var file_path_buf: [512]u8 = undefined;
    const file_path = buildFormulaFilePath(&file_path_buf, org, repo, formula_name) orelse return false;

    if (isLocalGitRepo(tap_path)) {
        execGitLog(allocator, tap_path, git_flags, file_path);
    }

    // Not a local git repo: try GitHub API fallback.
    fetchGitHubLog(allocator, org, repo, file_path, git_flags);
    return true;
}

/// Try to show the log for a cask. Returns true if the cask was found
/// and the log was shown (or execGitLog was called, which does not return).
fn tryCaskLog(allocator: Allocator, name: []const u8, git_flags: []const []const u8, config: Config) bool {
    var cask_idx = CaskIndex.loadOrBuild(allocator, config.cache) catch return false;
    const entry = cask_idx.lookup(name) orelse return false;
    const token = cask_idx.getString(entry.token_offset);

    // Cask index doesn't store tap; hardcode to homebrew/cask.
    const org = "homebrew";
    const repo = "cask";

    // Build tap path: {repository}/Library/Taps/homebrew/homebrew-cask
    var tap_path_buf: [1024]u8 = undefined;
    const tap_path = std.fmt.bufPrint(&tap_path_buf, "{s}/Library/Taps/{s}/homebrew-{s}", .{ config.repository, org, repo }) catch return false;

    // Build cask file path using the canonical token from the index.
    var file_path_buf: [512]u8 = undefined;
    const file_path = buildCaskFilePath(&file_path_buf, org, repo, token) orelse return false;

    if (isLocalGitRepo(tap_path)) {
        execGitLog(allocator, tap_path, git_flags, file_path);
    }

    // Not a local git repo: try GitHub API fallback.
    fetchGitHubLog(allocator, org, repo, file_path, git_flags);
    return true;
}

/// Build the relative file path for a formula within its tap.
/// homebrew/core uses "Formula/{letter}/{name}.rb"; other taps use "Formula/{name}.rb".
pub fn buildFormulaFilePath(buf: []u8, org: []const u8, repo: []const u8, name: []const u8) ?[]const u8 {
    if (name.len == 0) return null;

    const is_core = std.mem.eql(u8, org, "homebrew") and std.mem.eql(u8, repo, "core");
    if (is_core) {
        return std.fmt.bufPrint(buf, "Formula/{c}/{s}.rb", .{ name[0], name }) catch null;
    } else {
        return std.fmt.bufPrint(buf, "Formula/{s}.rb", .{name}) catch null;
    }
}

/// Build the relative file path for a cask within its tap.
/// homebrew/cask uses "Casks/{letter}/{token}.rb"; other taps use "Casks/{token}.rb".
pub fn buildCaskFilePath(buf: []u8, org: []const u8, repo: []const u8, name: []const u8) ?[]const u8 {
    if (name.len == 0) return null;

    const is_cask = std.mem.eql(u8, org, "homebrew") and std.mem.eql(u8, repo, "cask");
    if (is_cask) {
        return std.fmt.bufPrint(buf, "Casks/{c}/{s}.rb", .{ name[0], name }) catch null;
    } else {
        return std.fmt.bufPrint(buf, "Casks/{s}.rb", .{name}) catch null;
    }
}

/// Check if a path is a local git repository (has a .git directory or file).
pub fn isLocalGitRepo(path: []const u8) bool {
    var git_path_buf: [1024]u8 = undefined;
    const git_path = std.fmt.bufPrint(&git_path_buf, "{s}/.git", .{path}) catch return false;
    std.fs.accessAbsolute(git_path, .{}) catch return false;
    return true;
}

/// Fetch commit history from the GitHub API and print in git-log format.
/// Used when the tap is not cloned locally (e.g. API-only Homebrew installs).
fn fetchGitHubLog(allocator: Allocator, org: []const u8, repo: []const u8, file_path: []const u8, git_flags: []const []const u8) void {
    // Parse relevant flags from git_flags.
    var oneline = false;
    var max_count: usize = 30; // default
    var i: usize = 0;
    while (i < git_flags.len) : (i += 1) {
        const flag = git_flags[i];
        if (std.mem.eql(u8, flag, "--oneline")) {
            oneline = true;
        } else if (std.mem.eql(u8, flag, "-1")) {
            max_count = 1;
        } else if (std.mem.eql(u8, flag, "-n") or std.mem.eql(u8, flag, "--max-count")) {
            if (i + 1 < git_flags.len) {
                i += 1;
                max_count = std.fmt.parseInt(usize, git_flags[i], 10) catch max_count;
            }
        } else if (std.mem.startsWith(u8, flag, "-n")) {
            // Handle -n3 style (number directly after -n)
            max_count = std.fmt.parseInt(usize, flag[2..], 10) catch max_count;
        } else if (std.mem.startsWith(u8, flag, "--max-count=")) {
            max_count = std.fmt.parseInt(usize, flag[12..], 10) catch max_count;
        }
    }

    // Capitalize first letter of org for GitHub URL.
    var org_buf: [128]u8 = undefined;
    if (org.len > org_buf.len) return;
    @memcpy(org_buf[0..org.len], org);
    if (org_buf[0] >= 'a' and org_buf[0] <= 'z') {
        org_buf[0] -= 32;
    }
    const cap_org = org_buf[0..org.len];

    // Build URL: https://api.github.com/repos/{Org}/homebrew-{repo}/commits?path={file_path}&per_page={n}
    var url_buf: [1024]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "https://api.github.com/repos/{s}/homebrew-{s}/commits?path={s}&per_page={d}", .{ cap_org, repo, file_path, max_count }) catch return;

    var http = HttpClient.init(allocator);
    defer http.deinit();

    const body = http.fetchToMemory(allocator, url) catch {
        printStderr("bru: error: failed to fetch log from GitHub API\n");
        printStderr("The GitHub API may be rate-limited. Try again later or use `brew log`.\n");
        return;
    };
    defer allocator.free(body);

    // Parse and print commits from JSON response.
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const stdout = &w.interface;

    // Walk through JSON array elements manually.
    var pos: usize = 0;
    while (pos < body.len) {
        // Find next commit object by looking for "sha"
        const sha_start = findJsonKey(body, "\"sha\"", pos) orelse break;
        const sha = extractJsonStringAt(body, sha_start) orelse break;

        // Find commit.author.name and commit.message
        // The "commit" object comes after "sha" in GitHub's response.
        const commit_start = findJsonKey(body, "\"commit\"", sha_start) orelse break;
        const author_name = blk: {
            const author_start = findJsonKey(body, "\"author\"", commit_start) orelse break :blk "Unknown";
            const name_start = findJsonKey(body, "\"name\"", author_start) orelse break :blk "Unknown";
            break :blk extractJsonStringAt(body, name_start) orelse "Unknown";
        };
        const date = blk: {
            // Find "date" after "author" within the commit object.
            const author_start = findJsonKey(body, "\"author\"", commit_start) orelse break :blk "";
            const date_start = findJsonKey(body, "\"date\"", author_start) orelse break :blk "";
            break :blk extractJsonStringAt(body, date_start) orelse "";
        };
        const raw_message = blk: {
            const msg_start = findJsonKey(body, "\"message\"", commit_start) orelse break :blk "";
            break :blk extractJsonStringAt(body, msg_start) orelse "";
        };
        // Unescape JSON escape sequences (\n, \", etc.) in the message.
        const message = unescapeJsonString(allocator, raw_message) orelse raw_message;
        defer if (message.ptr != raw_message.ptr) allocator.free(message);

        if (oneline) {
            // Short SHA (first 7 chars) + first line of message.
            const short_sha = if (sha.len >= 7) sha[0..7] else sha;
            const first_line_end = std.mem.indexOfScalar(u8, message, '\n') orelse message.len;
            const first_line = message[0..first_line_end];
            stdout.print("{s} {s}\n", .{ short_sha, first_line }) catch {};
        } else {
            stdout.print("commit {s}\n", .{sha}) catch {};
            stdout.print("Author: {s}\n", .{author_name}) catch {};
            stdout.print("Date:   {s}\n", .{date}) catch {};
            stdout.print("\n", .{}) catch {};
            // Indent message lines with 4 spaces.
            var msg_rest: []const u8 = message;
            while (msg_rest.len > 0) {
                const line_end = std.mem.indexOfScalar(u8, msg_rest, '\n') orelse msg_rest.len;
                const line = msg_rest[0..line_end];
                stdout.print("    {s}\n", .{line}) catch {};
                msg_rest = if (line_end < msg_rest.len) msg_rest[line_end + 1 ..] else &.{};
            }
            stdout.print("\n", .{}) catch {};
        }

        // Advance past this commit object to find the next one.
        // Look for the next "sha" key after the current message.
        const next_search = findJsonKey(body, "\"message\"", commit_start) orelse break;
        pos = next_search + 1;
    }

    stdout.flush() catch {};
}

/// Find the position of a JSON key in the body starting from `from`.
fn findJsonKey(body: []const u8, key: []const u8, from: usize) ?usize {
    if (from >= body.len) return null;
    const idx = std.mem.indexOf(u8, body[from..], key) orelse return null;
    return from + idx;
}

/// Extract a JSON string value at the position of a key.
/// Expects: "key": "value" pattern. Returns the value (without quotes).
/// Handles basic escape sequences (\n, \", \\).
pub fn extractJsonString(body: []const u8, key: []const u8) ?[]const u8 {
    const key_pos = findJsonKey(body, key, 0) orelse return null;
    return extractJsonStringAt(body, key_pos);
}

/// Extract a JSON string value at the given position (position of the key).
/// Returns the raw JSON string content (with escape sequences like \n still
/// as literal backslash-n). Use `unescapeJsonString` to decode escapes.
fn extractJsonStringAt(body: []const u8, key_pos: usize) ?[]const u8 {
    // Skip past the key to find the colon and opening quote.
    var pos = key_pos;
    // Skip past the key string itself.
    if (pos < body.len and body[pos] == '"') {
        pos += 1;
        while (pos < body.len and body[pos] != '"') : (pos += 1) {}
        if (pos < body.len) pos += 1; // skip closing quote of key
    }
    // Skip whitespace and colon.
    while (pos < body.len and (body[pos] == ' ' or body[pos] == ':' or body[pos] == '\t' or body[pos] == '\n' or body[pos] == '\r')) : (pos += 1) {}
    // Now we should be at the opening quote of the value.
    if (pos >= body.len or body[pos] != '"') return null;
    pos += 1; // skip opening quote

    const start = pos;
    // Find the closing quote (handling escapes).
    while (pos < body.len) {
        if (body[pos] == '\\') {
            pos += 2; // skip escape sequence
            continue;
        }
        if (body[pos] == '"') break;
        pos += 1;
    }
    if (pos >= body.len) return null;
    return body[start..pos];
}

/// Unescape a JSON string in-place within a mutable buffer.
/// Handles \n, \t, \r, \\, \", \/.
/// Returns the unescaped slice (may be shorter than input).
fn unescapeJsonString(allocator: Allocator, raw: []const u8) ?[]u8 {
    // Check if unescaping is needed at all.
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) {
        const copy = allocator.dupe(u8, raw) catch return null;
        return copy;
    }

    // Count the unescaped length first so we can allocate exactly.
    var unescaped_len: usize = 0;
    {
        var ri: usize = 0;
        while (ri < raw.len) {
            if (raw[ri] == '\\' and ri + 1 < raw.len) {
                const next = raw[ri + 1];
                if (next == 'n' or next == 't' or next == 'r' or next == '\\' or next == '"' or next == '/') {
                    unescaped_len += 1;
                    ri += 2;
                } else {
                    unescaped_len += 1;
                    ri += 1;
                }
            } else {
                unescaped_len += 1;
                ri += 1;
            }
        }
    }

    const out = allocator.alloc(u8, unescaped_len) catch return null;
    var wi: usize = 0;
    var ri: usize = 0;
    while (ri < raw.len) {
        if (raw[ri] == '\\' and ri + 1 < raw.len) {
            switch (raw[ri + 1]) {
                'n' => {
                    out[wi] = '\n';
                    wi += 1;
                    ri += 2;
                },
                't' => {
                    out[wi] = '\t';
                    wi += 1;
                    ri += 2;
                },
                'r' => {
                    out[wi] = '\r';
                    wi += 1;
                    ri += 2;
                },
                '\\' => {
                    out[wi] = '\\';
                    wi += 1;
                    ri += 2;
                },
                '"' => {
                    out[wi] = '"';
                    wi += 1;
                    ri += 2;
                },
                '/' => {
                    out[wi] = '/';
                    wi += 1;
                    ri += 2;
                },
                else => {
                    out[wi] = raw[ri];
                    wi += 1;
                    ri += 1;
                },
            }
        } else {
            out[wi] = raw[ri];
            wi += 1;
            ri += 1;
        }
    }
    return out;
}

/// Write a string to stderr. Best-effort; ignores write errors.
fn printStderr(msg: []const u8) void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    stderr.writeAll(msg) catch {};
    stderr.flush() catch {};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "logCmd compiles and has correct signature" {
    // Smoke test: verifies the function signature is correct and the module compiles.
    const handler: @import("../dispatch.zig").CommandFn = logCmd;
    _ = handler;
}

test "buildFormulaFilePath for homebrew/core" {
    var buf: [512]u8 = undefined;
    const path = buildFormulaFilePath(&buf, "homebrew", "core", "wget");
    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("Formula/w/wget.rb", path.?);
}

test "buildFormulaFilePath for other taps" {
    var buf: [512]u8 = undefined;
    const path = buildFormulaFilePath(&buf, "user", "tap", "mod");
    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("Formula/mod.rb", path.?);
}

test "buildCaskFilePath for homebrew/cask" {
    var buf: [512]u8 = undefined;
    const path = buildCaskFilePath(&buf, "homebrew", "cask", "firefox");
    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("Casks/f/firefox.rb", path.?);
}

test "buildCaskFilePath for other taps" {
    var buf: [512]u8 = undefined;
    const path = buildCaskFilePath(&buf, "user", "tap", "myapp");
    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("Casks/myapp.rb", path.?);
}

test "buildFormulaFilePath returns null for empty name" {
    var buf: [512]u8 = undefined;
    const path = buildFormulaFilePath(&buf, "homebrew", "core", "");
    try std.testing.expect(path == null);
}

test "buildCaskFilePath returns null for empty name" {
    var buf: [512]u8 = undefined;
    const path = buildCaskFilePath(&buf, "homebrew", "cask", "");
    try std.testing.expect(path == null);
}

test "isLocalGitRepo returns false for nonexistent path" {
    try std.testing.expect(!isLocalGitRepo("/nonexistent/path/that/does/not/exist"));
}

test "extractJsonString parses simple value" {
    const json = "{\"name\": \"John\", \"age\": 30}";
    const value = extractJsonString(json, "\"name\"");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("John", value.?);
}

test "extractJsonString returns null for missing key" {
    const json = "{\"name\": \"John\"}";
    const value = extractJsonString(json, "\"missing\"");
    try std.testing.expect(value == null);
}

test "unescapeJsonString decodes escape sequences" {
    const allocator = std.testing.allocator;

    const result = unescapeJsonString(allocator, "line1\\nline2\\ttab");
    try std.testing.expect(result != null);
    defer allocator.free(result.?);
    try std.testing.expectEqualStrings("line1\nline2\ttab", result.?);
}

test "unescapeJsonString returns copy for plain strings" {
    const allocator = std.testing.allocator;

    const result = unescapeJsonString(allocator, "no escapes here");
    try std.testing.expect(result != null);
    defer allocator.free(result.?);
    try std.testing.expectEqualStrings("no escapes here", result.?);
}

test "execGitLog compiles" {
    // Dead-code test: verify it compiles. Cannot call since it's noreturn.
    if (false) {
        execGitLog(std.testing.allocator, "/tmp", &.{}, null);
    }
}
