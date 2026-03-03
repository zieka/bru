const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const Index = @import("../index.zig").Index;
const writeJsonStr = @import("../json_helpers.zig").writeJsonStr;

/// List all available formula names from the Homebrew API.
///
/// Usage: bru formulae [--json]
///
/// Prints one formula name per line, sorted alphabetically.
pub fn formulaeCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    var json_output = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        }
    }

    var idx = try Index.loadOrBuild(allocator, config.cache);
    const count = idx.entryCount();

    // Collect all formula names.
    var names = std.ArrayList([]const u8){};
    defer names.deinit(allocator);
    try names.ensureTotalCapacity(allocator, count);

    for (0..count) |i| {
        const entry = idx.getEntryByIndex(@intCast(i));
        const name = idx.getString(entry.name_offset);
        names.appendAssumeCapacity(name);
    }

    // Sort alphabetically.
    std.mem.sort([]const u8, names.items, {}, stringLessThan);

    // Output results.
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const stdout = &w.interface;

    if (json_output) {
        try stdout.writeAll("[");
        for (names.items, 0..) |name, i| {
            if (i > 0) try stdout.writeAll(",");
            try writeJsonStr(stdout, name);
        }
        try stdout.writeAll("]\n");
        try stdout.flush();
        return;
    }

    for (names.items) |name| {
        try stdout.print("{s}\n", .{name});
    }
    try stdout.flush();
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "formulaeCmd compiles and has correct signature" {
    const handler: @import("../dispatch.zig").CommandFn = formulaeCmd;
    _ = handler;
}
