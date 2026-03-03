const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const Index = @import("../index.zig").Index;
const CaskIndex = @import("../cask_index.zig").CaskIndex;
const Output = @import("../output.zig").Output;
const HttpClient = @import("../http.zig").HttpClient;
const log = @import("log.zig");
const fuzzy = @import("../fuzzy.zig");

const ParsedCatArgs = struct {
    package_name: ?[]const u8,
    force_formula: bool,
    force_cask: bool,
};

fn parseCatArgs(args: []const []const u8) ParsedCatArgs {
    var result = ParsedCatArgs{
        .package_name = null,
        .force_formula = false,
        .force_cask = false,
    };
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--formula") or std.mem.eql(u8, arg, "--formulae")) {
            result.force_formula = true;
        } else if (std.mem.eql(u8, arg, "--cask") or std.mem.eql(u8, arg, "--casks")) {
            result.force_cask = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (result.package_name == null) result.package_name = arg;
        }
    }
    return result;
}

/// Display the source code of a formula or cask.
///
/// Usage: bru cat [--formula | --cask] <formula|cask>
///
/// Looks up the package in the formula/cask index, then reads the .rb source
/// from the local tap directory or fetches it from GitHub.
pub fn catCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    const parsed = parseCatArgs(args);

    if (parsed.package_name == null) {
        const err_out = Output.initErr(config.no_color);
        err_out.err("This command requires a formula or cask argument.", .{});
        std.process.exit(1);
    }

    const the_name = parsed.package_name.?;

    // Try formula first (unless --cask was specified).
    if (!parsed.force_cask) {
        if (tryFormulaCat(allocator, the_name, config)) return;
    }

    // Try cask (unless --formula was specified).
    if (!parsed.force_formula) {
        if (tryCaskCat(allocator, the_name, config)) return;
    }

    // Nothing found: error with suggestions.
    var idx = Index.loadOrBuild(allocator, config.cache) catch {
        const err_out = Output.initErr(config.no_color);
        err_out.err("No available formula or cask with the name \"{s}\".", .{the_name});
        std.process.exit(1);
    };

    const err_out = Output.initErr(config.no_color);
    err_out.err("No available formula or cask with the name \"{s}\".", .{the_name});
    const similar = fuzzy.findSimilar(&idx, allocator, the_name, 3, 3) catch &.{};
    defer if (similar.len > 0) allocator.free(similar);
    if (similar.len > 0) {
        err_out.print("Did you mean?\n", .{});
        for (similar) |s| err_out.print("  {s}\n", .{s});
    }
    std.process.exit(1);
}

/// Try to display the source for a formula. Returns true if found.
fn tryFormulaCat(allocator: Allocator, name: []const u8, config: Config) bool {
    var idx = Index.loadOrBuild(allocator, config.cache) catch return false;
    const entry = idx.lookup(name) orelse return false;
    const tap = idx.getString(entry.tap_offset);
    const formula_name = idx.getString(entry.name_offset);
    if (tap.len == 0) return false;

    const slash = std.mem.indexOfScalar(u8, tap, '/') orelse return false;
    if (slash == 0 or slash + 1 >= tap.len) return false;
    const org = tap[0..slash];
    const repo = tap[slash + 1 ..];

    // Build relative file path within the tap.
    var file_path_buf: [512]u8 = undefined;
    const file_path = log.buildFormulaFilePath(&file_path_buf, org, repo, formula_name) orelse return false;

    // Build absolute path to local tap: {repository}/Library/Taps/{org}/homebrew-{repo}/{file_path}
    var abs_path_buf: [1024]u8 = undefined;
    const abs_path = std.fmt.bufPrint(&abs_path_buf, "{s}/Library/Taps/{s}/homebrew-{s}/{s}", .{ config.repository, org, repo, file_path }) catch return false;

    // Try reading from local tap first.
    if (readAndPrintFile(abs_path)) return true;

    // Fall back to GitHub raw content.
    return fetchAndPrintRawGitHub(allocator, org, repo, file_path);
}

/// Try to display the source for a cask. Returns true if found.
fn tryCaskCat(allocator: Allocator, name: []const u8, config: Config) bool {
    var cask_idx = CaskIndex.loadOrBuild(allocator, config.cache) catch return false;
    const entry = cask_idx.lookup(name) orelse return false;
    const token = cask_idx.getString(entry.token_offset);

    // Cask index doesn't store tap; hardcode to homebrew/cask.
    const org = "homebrew";
    const repo = "cask";

    // Build relative file path within the tap.
    var file_path_buf: [512]u8 = undefined;
    const file_path = log.buildCaskFilePath(&file_path_buf, org, repo, token) orelse return false;

    // Build absolute path to local tap.
    var abs_path_buf: [1024]u8 = undefined;
    const abs_path = std.fmt.bufPrint(&abs_path_buf, "{s}/Library/Taps/{s}/homebrew-{s}/{s}", .{ config.repository, org, repo, file_path }) catch return false;

    // Try reading from local tap first.
    if (readAndPrintFile(abs_path)) return true;

    // Fall back to GitHub raw content.
    return fetchAndPrintRawGitHub(allocator, org, repo, file_path);
}

/// Read a file from disk and print its contents to stdout.
/// Returns true if the file was read successfully.
fn readAndPrintFile(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer file.close();

    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const stdout = &w.interface;

    while (true) {
        var read_buf: [8192]u8 = undefined;
        const n = file.read(&read_buf) catch return false;
        if (n == 0) break;
        stdout.writeAll(read_buf[0..n]) catch return false;
    }
    stdout.flush() catch return false;
    return true;
}

/// Fetch a file from GitHub raw content and print it to stdout.
/// URL: https://raw.githubusercontent.com/{Org}/homebrew-{repo}/HEAD/{file_path}
/// Returns true if the file was fetched and printed successfully.
fn fetchAndPrintRawGitHub(allocator: Allocator, org: []const u8, repo: []const u8, file_path: []const u8) bool {
    // Capitalize first letter of org: "homebrew" -> "Homebrew"
    var org_buf: [128]u8 = undefined;
    if (org.len > org_buf.len) return false;
    @memcpy(org_buf[0..org.len], org);
    if (org_buf[0] >= 'a' and org_buf[0] <= 'z') {
        org_buf[0] -= 32;
    }
    const cap_org = org_buf[0..org.len];

    var url_buf: [1024]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "https://raw.githubusercontent.com/{s}/homebrew-{s}/HEAD/{s}", .{ cap_org, repo, file_path }) catch return false;

    var http = HttpClient.init(allocator);
    defer http.deinit();

    const body = http.fetchToMemory(allocator, url) catch return false;
    defer allocator.free(body);

    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const stdout = &w.interface;
    stdout.writeAll(body) catch return false;
    stdout.flush() catch return false;
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "catCmd compiles and has correct signature" {
    const handler: @import("../dispatch.zig").CommandFn = catCmd;
    _ = handler;
}

test "parseCatArgs extracts package name" {
    const args = &[_][]const u8{"wget"};
    const parsed = parseCatArgs(args);
    try std.testing.expectEqualStrings("wget", parsed.package_name.?);
    try std.testing.expect(!parsed.force_formula);
    try std.testing.expect(!parsed.force_cask);
}

test "parseCatArgs with --formula flag" {
    const args = &[_][]const u8{ "--formula", "git" };
    const parsed = parseCatArgs(args);
    try std.testing.expectEqualStrings("git", parsed.package_name.?);
    try std.testing.expect(parsed.force_formula);
    try std.testing.expect(!parsed.force_cask);
}

test "parseCatArgs with --cask flag" {
    const args = &[_][]const u8{ "--cask", "firefox" };
    const parsed = parseCatArgs(args);
    try std.testing.expectEqualStrings("firefox", parsed.package_name.?);
    try std.testing.expect(!parsed.force_formula);
    try std.testing.expect(parsed.force_cask);
}

test "parseCatArgs no arguments" {
    const args = &[_][]const u8{};
    const parsed = parseCatArgs(args);
    try std.testing.expect(parsed.package_name == null);
}

test "parseCatArgs skips unknown flags" {
    const args = &[_][]const u8{ "--verbose", "jq" };
    const parsed = parseCatArgs(args);
    try std.testing.expectEqualStrings("jq", parsed.package_name.?);
}

test "readAndPrintFile returns false for nonexistent file" {
    try std.testing.expect(!readAndPrintFile("/nonexistent/path/to/file.rb"));
}
