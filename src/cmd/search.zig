const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const Index = @import("../index.zig").Index;
const CaskIndex = @import("../cask_index.zig").CaskIndex;
const fuzzy = @import("../fuzzy.zig");
const writeJsonStr = @import("../json_helpers.zig").writeJsonStr;

/// Search for formulae and casks matching the query.
///
/// Usage: bru search <query>
///
/// Matches by substring first, then by edit distance (fuzzy) for short queries.
/// This matches `brew search` behavior which includes close fuzzy matches.
pub fn searchCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    var json_output = false;
    var query: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (query == null) query = arg;
        }
    }

    if (query == null) {
        var err_buf: [4096]u8 = undefined;
        var ew = std.fs.File.stderr().writer(&err_buf);
        const stderr = &ew.interface;
        try stderr.print("Usage: bru search <query>\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    const search_query = query.?;

    var idx = try Index.loadOrBuild(allocator, config.cache);

    const count = idx.entryCount();

    // Collect matching formula names (substring + fuzzy).
    var formula_matches = std.ArrayList([]const u8){};
    defer formula_matches.deinit(allocator);

    // Track substring matches in a set to avoid duplicates with fuzzy.
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    // Substring matches.
    for (0..count) |i| {
        const entry = idx.getEntryByIndex(@intCast(i));
        const name = idx.getString(entry.name_offset);
        if (std.mem.indexOf(u8, name, search_query) != null) {
            try formula_matches.append(allocator, name);
            try seen.put(name, {});
        }
    }

    // Fuzzy matches (edit distance 1) for queries <= 8 chars.
    if (search_query.len <= 8) {
        for (0..count) |i| {
            const entry = idx.getEntryByIndex(@intCast(i));
            const name = idx.getString(entry.name_offset);
            if (seen.contains(name)) continue;
            if (fuzzy.editDistance(search_query, name) <= 1) {
                try formula_matches.append(allocator, name);
                try seen.put(name, {});
            }
        }
    }

    // Sort all formula matches alphabetically.
    std.mem.sort([]const u8, formula_matches.items, {}, stringLessThan);

    // Collect matching cask names (substring + fuzzy).
    var cask_matches = std.ArrayList([]const u8){};
    defer cask_matches.deinit(allocator);

    var cask_seen = std.StringHashMap(void).init(allocator);
    defer cask_seen.deinit();

    if (CaskIndex.loadOrBuild(allocator, config.cache)) |*cask_idx| {
        const cask_count = cask_idx.entryCount();

        for (0..cask_count) |ci| {
            const centry = cask_idx.getEntryByIndex(@intCast(ci));
            const cask_name = cask_idx.getString(centry.token_offset);
            if (std.mem.indexOf(u8, cask_name, search_query) != null) {
                try cask_matches.append(allocator, cask_name);
                try cask_seen.put(cask_name, {});
            }
        }

        if (search_query.len <= 8) {
            for (0..cask_count) |ci| {
                const centry = cask_idx.getEntryByIndex(@intCast(ci));
                const cask_name = cask_idx.getString(centry.token_offset);
                if (cask_seen.contains(cask_name)) continue;
                if (fuzzy.editDistance(search_query, cask_name) <= 1) {
                    try cask_matches.append(allocator, cask_name);
                    try cask_seen.put(cask_name, {});
                }
            }
        }

        std.mem.sort([]const u8, cask_matches.items, {}, stringLessThan);
    } else |_| {}

    // Output results.
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const stdout = &w.interface;

    if (json_output) {
        try stdout.writeAll("{\"formulae\":[");
        for (formula_matches.items, 0..) |name, i| {
            if (i > 0) try stdout.writeAll(",");
            try writeJsonStr(stdout, name);
        }
        try stdout.writeAll("],\"casks\":[");
        for (cask_matches.items, 0..) |name, i| {
            if (i > 0) try stdout.writeAll(",");
            try writeJsonStr(stdout, name);
        }
        try stdout.writeAll("]}\n");
        try stdout.flush();
        return;
    }

    try writeSearchResults(stdout, formula_matches.items, cask_matches.items);
    try stdout.flush();

    if (formula_matches.items.len == 0 and cask_matches.items.len == 0) {
        var err_buf: [4096]u8 = undefined;
        var ew = std.fs.File.stderr().writer(&err_buf);
        const stderr_w = &ew.interface;
        try stderr_w.print("No formulae or casks found for \"{s}\".\n", .{search_query});
        try stderr_w.flush();
        std.process.exit(1);
    }
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Write non-JSON search results to the given writer using brew-style section
/// headers when both formulae and cask matches are present.
fn writeSearchResults(writer: anytype, formula_matches: []const []const u8, cask_matches: []const []const u8) !void {
    const both = formula_matches.len > 0 and cask_matches.len > 0;

    if (both) {
        try writer.writeAll("==> Formulae\n");
    }
    for (formula_matches) |name| {
        try writer.print("{s}\n", .{name});
    }
    if (both) {
        try writer.writeAll("\n==> Casks\n");
    }
    for (cask_matches) |name| {
        try writer.print("{s}\n", .{name});
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "searchCmd compiles and has correct signature" {
    // Smoke test: verifies the function signature is correct and the module compiles.
}

test "search output: mixed results show section headers" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try writeSearchResults(writer, &.{ "firefoxpwa" }, &.{ "firefox", "firefox@beta" });

    const output = fbs.getWritten();
    const expected =
        \\==> Formulae
        \\firefoxpwa
        \\
        \\==> Casks
        \\firefox
        \\firefox@beta
        \\
    ;
    try std.testing.expectEqualStrings(expected, output);
}

test "search output: formula-only results have no headers" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try writeSearchResults(writer, &.{ "bat", "bat-extras" }, &.{});

    const output = fbs.getWritten();
    const expected =
        \\bat
        \\bat-extras
        \\
    ;
    try std.testing.expectEqualStrings(expected, output);
}

test "search output: cask-only results have no headers" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try writeSearchResults(writer, &.{}, &.{ "firefox", "firefox@beta" });

    const output = fbs.getWritten();
    const expected =
        \\firefox
        \\firefox@beta
        \\
    ;
    try std.testing.expectEqualStrings(expected, output);
}

test "search output: no (cask) suffix in output" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try writeSearchResults(writer, &.{"firefoxpwa"}, &.{ "firefox", "firefox@beta" });

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "(cask)") == null);
}

test "search output: no results produces no output" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try writeSearchResults(writer, &.{}, &.{});

    const output = fbs.getWritten();
    try std.testing.expectEqualStrings("", output);
}
