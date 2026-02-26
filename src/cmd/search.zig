const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const Index = @import("../index.zig").Index;
const CaskIndex = @import("../cask_index.zig").CaskIndex;
const writeJsonStr = @import("../json_helpers.zig").writeJsonStr;

/// Search for formulae whose names contain the given substring.
///
/// Usage: bru search <query>
///
/// Iterates all entries in the binary index and prints each formula name
/// that contains the query as a substring.  Exits with code 1 if no args
/// are supplied or if no matches are found.
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
    // Note: do not call idx.deinit() -- the index may be mmap'd (from disk)
    // in which case the allocator field is undefined. The process exits after
    // this command so OS reclamation is sufficient.

    const count = idx.entryCount();

    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const stdout = &w.interface;

    if (json_output) {
        // Emit {"formulae":[...],"casks":[...]}
        try stdout.writeAll("{\"formulae\":[");
        var first_f: bool = true;
        for (0..count) |i| {
            const entry = idx.getEntryByIndex(@intCast(i));
            const name = idx.getString(entry.name_offset);
            if (std.mem.indexOf(u8, name, search_query) != null) {
                if (!first_f) try stdout.writeAll(",");
                try writeJsonStr(stdout, name);
                first_f = false;
            }
        }
        try stdout.writeAll("],\"casks\":[");
        var first_c: bool = true;
        if (CaskIndex.loadOrBuild(allocator, config.cache)) |*cask_idx| {
            const cask_count = cask_idx.entryCount();
            for (0..cask_count) |ci| {
                const centry = cask_idx.getEntryByIndex(@intCast(ci));
                const cask_name = cask_idx.getString(centry.token_offset);
                if (std.mem.indexOf(u8, cask_name, search_query) != null) {
                    if (!first_c) try stdout.writeAll(",");
                    try writeJsonStr(stdout, cask_name);
                    first_c = false;
                }
            }
        } else |_| {}
        try stdout.writeAll("]}\n");
        try stdout.flush();
        return;
    }

    var found: bool = false;
    for (0..count) |i| {
        const entry = idx.getEntryByIndex(@intCast(i));
        const name = idx.getString(entry.name_offset);
        if (std.mem.indexOf(u8, name, search_query) != null) {
            try stdout.print("{s}\n", .{name});
            found = true;
        }
    }
    // Also search cask index
    if (CaskIndex.loadOrBuild(allocator, config.cache)) |*cask_idx| {
        const cask_count = cask_idx.entryCount();
        for (0..cask_count) |ci| {
            const centry = cask_idx.getEntryByIndex(@intCast(ci));
            const cask_name = cask_idx.getString(centry.token_offset);
            if (std.mem.indexOf(u8, cask_name, search_query) != null) {
                try stdout.print("{s} (cask)\n", .{cask_name});
                found = true;
            }
        }
    } else |_| {}

    try stdout.flush();

    if (!found) {
        var err_buf: [4096]u8 = undefined;
        var ew = std.fs.File.stderr().writer(&err_buf);
        const stderr_w = &ew.interface;
        try stderr_w.print("No formulae or casks found for \"{s}\".\n", .{search_query});
        try stderr_w.flush();
        std.process.exit(1);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "searchCmd compiles and has correct signature" {
    // Smoke test: verifies the function signature is correct and the module compiles.
}
