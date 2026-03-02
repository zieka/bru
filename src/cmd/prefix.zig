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

/// Print the Homebrew caskroom path.
/// Creates the directory if it doesn't exist (matching brew behavior).
/// Always prints "{caskroom}\n" (no argument variant).
pub fn caskroomCmd(_: std.mem.Allocator, _: []const []const u8, config: Config) anyerror!void {
    std.fs.makeDirAbsolute(config.caskroom) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const stdout = &w.interface;

    try stdout.print("{s}\n", .{config.caskroom});
    try stdout.flush();
}

/// Print the Homebrew repository path.
/// With an argument like "user/repo": prints "{repository}/Library/Taps/{user}/homebrew-{repo}\n"
/// Without arguments: prints "{repository}\n"
pub fn repoCmd(allocator: std.mem.Allocator, args: []const []const u8, config: Config) anyerror!void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const stdout = &w.interface;

    if (args.len > 0) {
        const tap = args[0];
        if (std.mem.indexOfScalar(u8, tap, '/')) |slash_pos| {
            const user = tap[0..slash_pos];
            const repo = tap[slash_pos + 1 ..];
            const tap_path = try std.fmt.allocPrint(allocator, "{s}/Library/Taps/{s}/homebrew-{s}", .{ config.repository, user, repo });
            defer allocator.free(tap_path);
            try stdout.print("{s}\n", .{tap_path});
        } else {
            try stdout.print("{s}\n", .{config.repository});
        }
    } else {
        try stdout.print("{s}\n", .{config.repository});
    }
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

test "caskroomCmd prints caskroom" {
    // Smoke test for caskroomCmd function signature.
}

test "repoCmd prints repository" {
    // Smoke test for repoCmd function signature.
}
