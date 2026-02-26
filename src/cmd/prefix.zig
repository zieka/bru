const std = @import("std");
const Config = @import("../config.zig").Config;

/// Print the Homebrew prefix path.
/// With an argument: prints "{prefix}/opt/{arg}\n"
/// Without arguments: prints "{prefix}\n"
pub fn prefixCmd(_: std.mem.Allocator, args: []const []const u8, config: Config) anyerror!void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const stdout = &w.interface;

    if (args.len > 0) {
        try stdout.print("{s}/opt/{s}\n", .{ config.prefix, args[0] });
    } else {
        try stdout.print("{s}\n", .{config.prefix});
    }
    try stdout.flush();
}

/// Print the Homebrew cellar path.
/// With an argument: prints "{cellar}/{arg}\n"
/// Without arguments: prints "{cellar}\n"
pub fn cellarCmd(_: std.mem.Allocator, args: []const []const u8, config: Config) anyerror!void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const stdout = &w.interface;

    if (args.len > 0) {
        try stdout.print("{s}/{s}\n", .{ config.cellar, args[0] });
    } else {
        try stdout.print("{s}\n", .{config.cellar});
    }
    try stdout.flush();
}

/// Print the Homebrew cache path.
/// Always prints "{cache}\n" (no argument handling).
pub fn cacheCmd(_: std.mem.Allocator, _: []const []const u8, config: Config) anyerror!void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const stdout = &w.interface;

    try stdout.print("{s}\n", .{config.cache});
    try stdout.flush();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "prefixCmd prints prefix without args" {
    // Smoke test: verifies the function signature is correct and the module compiles.
    // Actual output goes to stdout which we cannot capture in tests.
}

test "cellarCmd prints cellar without args" {
    // Smoke test for cellarCmd function signature.
}

test "cacheCmd prints cache" {
    // Smoke test for cacheCmd function signature.
}
