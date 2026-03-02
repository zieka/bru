const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const Index = @import("../index.zig").Index;
const CaskIndex = @import("../cask_index.zig").CaskIndex;
const Output = @import("../output.zig").Output;
const fuzzy = @import("../fuzzy.zig");

const SearchMode = enum { search, name, description };

/// Show the description of a formula or cask.
///
/// Usage: bru desc <formula|cask> [...]
///        bru desc --search <text>
///        bru desc --name <text>
///        bru desc --description <text>
///
/// With one or more names, prints the description for each.
/// With --search, --name, or --description, searches all descriptions.
pub fn descCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    var force_formula = false;
    var force_cask = false;
    var search_mode: ?SearchMode = null;

    var names = std.ArrayList([]const u8){};
    defer names.deinit(allocator);

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--formula") or std.mem.eql(u8, arg, "--formulae")) {
            force_formula = true;
        } else if (std.mem.eql(u8, arg, "--cask") or std.mem.eql(u8, arg, "--casks")) {
            force_cask = true;
        } else if (std.mem.eql(u8, arg, "--search") or std.mem.eql(u8, arg, "-s")) {
            search_mode = .search;
        } else if (std.mem.eql(u8, arg, "--name") or std.mem.eql(u8, arg, "-n")) {
            search_mode = .name;
        } else if (std.mem.eql(u8, arg, "--description") or std.mem.eql(u8, arg, "-d")) {
            search_mode = .description;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try names.append(allocator, arg);
        }
    }

    if (names.items.len == 0) {
        const err_out = Output.initErr(config.no_color);
        err_out.print("Usage: bru desc <formula|cask> [...]\n", .{});
        err_out.print("       bru desc --search <text>\n", .{});
        std.process.exit(1);
    }

    if (search_mode) |mode| {
        // In search mode, use the first name as the query.
        try searchDescs(allocator, names.items[0], mode, force_formula, force_cask, config);
        return;
    }

    try lookupDescs(allocator, names.items, force_formula, force_cask, config);
}

/// Look up descriptions for one or more package names by direct index lookup.
fn lookupDescs(
    allocator: Allocator,
    names: []const []const u8,
    force_formula: bool,
    force_cask: bool,
    config: Config,
) !void {
    // Load indices as needed.
    var formula_idx: ?Index = if (!force_cask)
        Index.loadOrBuild(allocator, config.cache) catch null
    else
        null;

    var cask_idx: ?CaskIndex = if (!force_formula)
        CaskIndex.loadOrBuild(allocator, config.cache) catch null
    else
        null;

    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const stdout = &w.interface;

    var any_missing = false;

    for (names) |name| {
        var found = false;

        // Try formula index first.
        if (formula_idx) |*idx| {
            if (idx.lookup(name)) |entry| {
                const desc_text = idx.getString(entry.desc_offset);
                try writeDescLine(stdout, name, "", desc_text);
                found = true;
            }
        }

        // Try cask index if not found as formula (or if --cask is forced).
        if (!found) {
            if (cask_idx) |*cidx| {
                if (cidx.lookup(name)) |centry| {
                    const desc_text = cidx.getString(centry.desc_offset);
                    const display_name = cidx.getString(centry.name_offset);
                    try writeDescLine(stdout, name, display_name, desc_text);
                    found = true;
                }
            }
        }

        if (!found) {
            const err_out = Output.initErr(config.no_color);
            err_out.err("No available formula or cask with the name \"{s}\".", .{name});

            // Show fuzzy suggestions from formula index.
            if (formula_idx) |*idx| {
                const similar = fuzzy.findSimilar(idx, allocator, name, 3, 3) catch &.{};
                defer if (similar.len > 0) allocator.free(similar);
                if (similar.len > 0) {
                    err_out.print("Did you mean?\n", .{});
                    for (similar) |s| err_out.print("  {s}\n", .{s});
                }
            }

            any_missing = true;
        }
    }

    try stdout.flush();

    if (any_missing) std.process.exit(1);
}

/// Format a single description line to a writer.
/// Formula format: "name: description"
/// Cask format: "token: (display_name) description"
fn writeDescLine(writer: anytype, name: []const u8, display_name: []const u8, desc_text: []const u8) !void {
    try writer.print("{s}: ", .{name});
    if (display_name.len > 0 and !std.mem.eql(u8, display_name, name)) {
        try writer.print("({s}) ", .{display_name});
    }
    if (desc_text.len > 0) {
        try writer.print("{s}", .{desc_text});
    }
    try writer.writeAll("\n");
}

/// Check if a query string is flanked by slashes (regex syntax).
/// Returns the inner pattern if so, or null for plain text.
fn parseRegexQuery(query: []const u8) ?[]const u8 {
    if (query.len >= 2 and query[0] == '/' and query[query.len - 1] == '/') {
        return query[1 .. query.len - 1];
    }
    return null;
}

/// Check if a string contains the query as a case-insensitive substring.
fn containsText(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    const end = haystack.len - needle.len + 1;
    for (0..end) |i| {
        var match = true;
        for (0..needle.len) |j| {
            if (toLower(haystack[i + j]) != toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// Search all formulae and/or casks for entries whose name or description
/// matches the given query (case-insensitive substring match).
fn searchDescs(allocator: Allocator, query: []const u8, mode: SearchMode, force_formula: bool, force_cask: bool, config: Config) !void {
    // For regex queries flanked by /.../, we treat the inner text as a substring match.
    // Full POSIX regex support would require libc or a regex engine; substring matching
    // covers the common use case and matches bru's "fast native" philosophy.
    const effective_query = parseRegexQuery(query) orelse query;

    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const stdout = &w.interface;

    const out = Output.init(config.no_color);

    // --- Formulae ---
    if (!force_cask) {
        out.section("Formulae");
        if (Index.loadOrBuild(allocator, config.cache)) |*idx| {
            const count = idx.entryCount();
            for (0..count) |i| {
                const entry = idx.getEntryByIndex(@intCast(i));
                const name = idx.getString(entry.name_offset);
                const desc_text = idx.getString(entry.desc_offset);

                const matches = switch (mode) {
                    .search => containsText(name, effective_query) or containsText(desc_text, effective_query),
                    .name => containsText(name, effective_query),
                    .description => containsText(desc_text, effective_query),
                };

                if (matches) {
                    try writeDescLine(stdout, name, "", desc_text);
                }
            }
        } else |_| {}
    }

    // --- Casks ---
    if (!force_formula) {
        out.section("Casks");
        if (CaskIndex.loadOrBuild(allocator, config.cache)) |*cask_idx| {
            const cask_count = cask_idx.entryCount();
            for (0..cask_count) |ci| {
                const centry = cask_idx.getEntryByIndex(@intCast(ci));
                const token = cask_idx.getString(centry.token_offset);
                const display_name = cask_idx.getString(centry.name_offset);
                const desc_text = cask_idx.getString(centry.desc_offset);

                const matches = switch (mode) {
                    .search => containsText(token, effective_query) or containsText(desc_text, effective_query),
                    .name => containsText(token, effective_query),
                    .description => containsText(desc_text, effective_query),
                };

                if (matches) {
                    try writeDescLine(stdout, token, display_name, desc_text);
                }
            }
        } else |_| {}
    }

    try stdout.flush();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "descCmd compiles and has correct signature" {
    const handler: @import("../dispatch.zig").CommandFn = descCmd;
    _ = handler;
}

test "writeDescLine formula format" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try writeDescLine(writer, "git", "", "Distributed revision control system");

    const output = fbs.getWritten();
    try std.testing.expectEqualStrings("git: Distributed revision control system\n", output);
}

test "writeDescLine cask format with display name" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try writeDescLine(writer, "firefox", "Mozilla Firefox", "Web browser");

    const output = fbs.getWritten();
    try std.testing.expectEqualStrings("firefox: (Mozilla Firefox) Web browser\n", output);
}

test "writeDescLine cask with same name as display name" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try writeDescLine(writer, "firefox", "firefox", "Web browser");

    const output = fbs.getWritten();
    try std.testing.expectEqualStrings("firefox: Web browser\n", output);
}

test "parseRegexQuery detects regex" {
    try std.testing.expectEqualStrings("^git$", parseRegexQuery("/^git$/").?);
}

test "parseRegexQuery returns null for plain text" {
    try std.testing.expect(parseRegexQuery("json") == null);
}

test "parseRegexQuery single slash not regex" {
    try std.testing.expect(parseRegexQuery("/") == null);
}

test "containsText case insensitive" {
    try std.testing.expect(containsText("Distributed revision control system", "revision"));
    try std.testing.expect(containsText("Distributed revision control system", "Revision"));
    try std.testing.expect(!containsText("Distributed revision control system", "nonexistent"));
}

test "containsText empty needle" {
    try std.testing.expect(containsText("anything", ""));
}

test "writeDescLine with empty description" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    try writeDescLine(writer, "somepkg", "", "");
    const output = fbs.getWritten();
    try std.testing.expectEqualStrings("somepkg: \n", output);
}
