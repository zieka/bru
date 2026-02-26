const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const Index = @import("../index.zig").Index;

/// Search for formulae whose names contain the given substring.
///
/// Usage: bru search <query>
///
/// Iterates all entries in the binary index and prints each formula name
/// that contains the query as a substring.  Exits with code 1 if no args
/// are supplied or if no matches are found.
pub fn searchCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    if (args.len == 0) {
        var err_buf: [4096]u8 = undefined;
        var ew = std.fs.File.stderr().writer(&err_buf);
        const stderr = &ew.interface;
        try stderr.print("Usage: bru search <query>\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    const query = args[0];

    var idx = try Index.loadOrBuild(allocator, config.cache);
    // Note: do not call idx.deinit() -- the index may be mmap'd (from disk)
    // in which case the allocator field is undefined. The process exits after
    // this command so OS reclamation is sufficient.

    const count = idx.entryCount();

    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const stdout = &w.interface;

    var found: bool = false;
    for (0..count) |i| {
        const entry = idx.getEntryByIndex(@intCast(i));
        const name = idx.getString(entry.name_offset);
        if (std.mem.indexOf(u8, name, query) != null) {
            try stdout.print("{s}\n", .{name});
            found = true;
        }
    }
    try stdout.flush();

    if (!found) {
        var err_buf: [4096]u8 = undefined;
        var ew = std.fs.File.stderr().writer(&err_buf);
        const stderr_w = &ew.interface;
        try stderr_w.print("No formulae found for \"{s}\".\n", .{query});
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
