const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;

/// Display system configuration information in a brew-compatible format.
///
/// Prints Homebrew-compatible environment details including version, paths,
/// CPU architecture, OS, and (on macOS) the system version via `sw_vers`.
pub fn configCmd(allocator: Allocator, _: []const []const u8, config: Config) anyerror!void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const stdout = &w.interface;

    try stdout.print("HOMEBREW_VERSION: bru 0.1.0 (brew compat)\n", .{});
    try stdout.print("ORIGIN: https://github.com/user/bru\n", .{});
    try stdout.print("HOMEBREW_PREFIX: {s}\n", .{config.prefix});
    try stdout.print("HOMEBREW_CELLAR: {s}\n", .{config.cellar});
    try stdout.print("HOMEBREW_CASKROOM: {s}\n", .{config.caskroom});
    try stdout.print("HOMEBREW_CACHE: {s}\n", .{config.cache});
    try stdout.print("CPU: {s}\n", .{@tagName(builtin.cpu.arch)});
    try stdout.print("OS: {s}\n", .{@tagName(builtin.os.tag)});

    const macos_version = getMacOSVersion(allocator);
    defer if (macos_version) |v| allocator.free(v);
    try stdout.print("macOS: {s}\n", .{macos_version orelse "unknown"});

    try stdout.flush();
}

/// Run `sw_vers -productVersion` and return the trimmed output.
/// Caller must free the returned slice with the same allocator.
/// Returns null if the command fails for any reason.
fn getMacOSVersion(allocator: Allocator) ?[]const u8 {
    if (comptime builtin.os.tag != .macos) return null;

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "sw_vers", "-productVersion" },
    }) catch return null;

    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    // Check for successful exit.
    switch (result.term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }

    // Trim trailing whitespace from stdout.
    const trimmed = std.mem.trimRight(u8, result.stdout, &.{ '\n', '\r', ' ', '\t' });
    if (trimmed.len == 0) return null;

    // Duplicate the trimmed content so caller has a clean allocation to free.
    return allocator.dupe(u8, trimmed) catch null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "configCmd compiles and has correct signature" {
    // Smoke test: verifies the function signature is correct and the module compiles.
    const handler: @import("../dispatch.zig").CommandFn = configCmd;
    _ = handler;
}

test "getMacOSVersion returns a version string on macOS" {
    if (comptime builtin.os.tag != .macos) return;

    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_instance.deinit();
    const allocator = gpa_instance.allocator();

    const version = getMacOSVersion(allocator);
    defer if (version) |v| allocator.free(v);

    // On macOS, sw_vers should succeed and return a non-empty string.
    try std.testing.expect(version != null);
    try std.testing.expect(version.?.len > 0);

    // Version should contain at least one dot (e.g., "15.3.1").
    try std.testing.expect(std.mem.indexOfScalar(u8, version.?, '.') != null);
}
