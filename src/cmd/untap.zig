const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const Output = @import("../output.zig").Output;

/// Remove a previously tapped third-party repository.
///
/// Usage: bru untap [--force] <tap> [...]
///
/// Options:
///   --force, -f  Untap even if formulae or casks from this tap are currently installed
pub fn untapCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    var force = false;
    var tap_args = std.ArrayList([]const u8){};
    defer tap_args.deinit(allocator);

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            force = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try tap_args.append(allocator, arg);
        }
    }

    const err_out = Output.initErr(config.no_color);

    if (tap_args.items.len == 0) {
        err_out.err("This command requires a tap argument.", .{});
        err_out.print("Try: bru untap user/repo\n", .{});
        std.process.exit(1);
    }

    for (tap_args.items) |tap_arg| {
        removeTap(allocator, tap_arg, force, config);
    }
}

fn removeTap(allocator: Allocator, tap_arg: []const u8, force: bool, config: Config) void {
    const err_out = Output.initErr(config.no_color);
    const out = Output.init(config.no_color);

    const parsed = parseTapName(tap_arg) orelse {
        err_out.err("Invalid tap name \"{s}\". Expected format: user/repo", .{tap_arg});
        std.process.exit(1);
    };

    // Display name never has "homebrew-" prefix.
    const display_repo = if (std.mem.startsWith(u8, parsed.repo, "homebrew-"))
        parsed.repo["homebrew-".len..]
    else
        parsed.repo;

    // Refuse to untap core taps.
    if (std.mem.eql(u8, parsed.user, "homebrew")) {
        if (std.mem.eql(u8, display_repo, "core") or std.mem.eql(u8, display_repo, "cask")) {
            err_out.err("Refusing to untap homebrew/{s}. Core taps cannot be removed.", .{display_repo});
            std.process.exit(1);
        }
    }

    // Directory name always has "homebrew-" prefix.
    var repo_dir_buf: [256]u8 = undefined;
    const repo_dir_name = if (std.mem.startsWith(u8, parsed.repo, "homebrew-"))
        parsed.repo
    else
        std.fmt.bufPrint(&repo_dir_buf, "homebrew-{s}", .{parsed.repo}) catch {
            err_out.err("Repository name too long", .{});
            std.process.exit(1);
        };

    var tap_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tap_path = std.fmt.bufPrint(&tap_path_buf, "{s}/Library/Taps/{s}/{s}", .{
        config.repository, parsed.user, repo_dir_name,
    }) catch {
        err_out.err("Tap path too long", .{});
        std.process.exit(1);
    };

    // Validate the tap exists.
    {
        var dir = std.fs.openDirAbsolute(tap_path, .{}) catch {
            err_out.err("No such tap: {s}/{s}", .{ parsed.user, display_repo });
            std.process.exit(1);
        };
        dir.close();
    }

    // Unless --force, warn if installed formulae/casks come from this tap.
    if (!force) {
        const installed = countInstalledFromTap(allocator, tap_path, config);
        if (installed.formulae > 0 or installed.casks > 0) {
            var msg_buf: [256]u8 = undefined;
            const msg = if (installed.formulae > 0 and installed.casks > 0)
                std.fmt.bufPrint(&msg_buf, "{s}/{s} has {d} installed {s} and {d} installed {s}.", .{
                    parsed.user,
                    display_repo,
                    installed.formulae,
                    if (installed.formulae == 1) @as([]const u8, "formula") else "formulae",
                    installed.casks,
                    if (installed.casks == 1) @as([]const u8, "cask") else "casks",
                }) catch "has installed packages."
            else if (installed.formulae > 0)
                std.fmt.bufPrint(&msg_buf, "{s}/{s} has {d} installed {s}.", .{
                    parsed.user,
                    display_repo,
                    installed.formulae,
                    if (installed.formulae == 1) @as([]const u8, "formula") else "formulae",
                }) catch "has installed formulae."
            else
                std.fmt.bufPrint(&msg_buf, "{s}/{s} has {d} installed {s}.", .{
                    parsed.user,
                    display_repo,
                    installed.casks,
                    if (installed.casks == 1) @as([]const u8, "cask") else "casks",
                }) catch "has installed casks.";

            err_out.err("{s}", .{msg});
            err_out.print("Use --force to untap anyway.\n", .{});
            std.process.exit(1);
        }
    }

    // Print section header.
    var section_buf: [256]u8 = undefined;
    const section_msg = std.fmt.bufPrint(&section_buf, "Untapping {s}/{s}", .{
        parsed.user, display_repo,
    }) catch "Untapping";
    out.section(section_msg);

    // Remove the tap directory.
    std.fs.deleteTreeAbsolute(tap_path) catch |err| {
        err_out.err("Failed to remove tap directory: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    // Clean up empty parent directory (user dir under Taps/).
    var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
    const parent_path = std.fmt.bufPrint(&parent_buf, "{s}/Library/Taps/{s}", .{
        config.repository, parsed.user,
    }) catch return;
    removeIfEmptyDir(parent_path);

    var summary_buf: [256]u8 = undefined;
    const summary = std.fmt.bufPrint(&summary_buf, "Untapped {s}/{s}", .{
        parsed.user, display_repo,
    }) catch "Untapped";
    out.section(summary);
}

/// Parse "user/repo" into components. Returns null for invalid format.
fn parseTapName(tap: []const u8) ?struct { user: []const u8, repo: []const u8 } {
    const slash = std.mem.indexOfScalar(u8, tap, '/') orelse return null;
    if (slash == 0 or slash + 1 >= tap.len) return null;
    if (std.mem.indexOfScalarPos(u8, tap, slash + 1, '/') != null) return null;
    return .{ .user = tap[0..slash], .repo = tap[slash + 1 ..] };
}

/// Count formulae and casks from a tap that are currently installed.
fn countInstalledFromTap(
    allocator: Allocator,
    tap_path: []const u8,
    config: Config,
) struct { formulae: usize, casks: usize } {
    return .{
        .formulae = countInstalledRb(allocator, tap_path, "Formula", config.prefix, "Cellar"),
        .casks = countInstalledRb(allocator, tap_path, "Casks", config.prefix, "Caskroom"),
    };
}

/// Count .rb files in a tap subdirectory whose basenames (sans .rb) are
/// installed in the given cellar-like directory under prefix.
fn countInstalledRb(
    allocator: Allocator,
    tap_path: []const u8,
    subdir: []const u8,
    prefix: []const u8,
    cellar_name: []const u8,
) usize {
    var tap_sub_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tap_sub_path = std.fmt.bufPrint(&tap_sub_buf, "{s}/{s}", .{ tap_path, subdir }) catch return 0;

    var dir = std.fs.openDirAbsolute(tap_sub_path, .{ .iterate = true }) catch return 0;
    defer dir.close();

    var count: usize = 0;
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".rb")) {
            const name = entry.name[0 .. entry.name.len - 3]; // strip .rb
            if (isInstalledIn(allocator, prefix, cellar_name, name)) count += 1;
        } else if (entry.kind == .directory and entry.name.len == 1) {
            // Sharded layout: Formula/a/formula.rb
            var sub_dir = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
            defer sub_dir.close();
            var sub_iter = sub_dir.iterate();
            while (sub_iter.next() catch null) |sub_entry| {
                if (sub_entry.kind == .file and std.mem.endsWith(u8, sub_entry.name, ".rb")) {
                    const name = sub_entry.name[0 .. sub_entry.name.len - 3];
                    if (isInstalledIn(allocator, prefix, cellar_name, name)) count += 1;
                }
            }
        }
    }
    return count;
}

/// Check if a formula/cask name has a directory under {prefix}/{cellar_name}/{name}.
fn isInstalledIn(_: Allocator, prefix: []const u8, cellar_name: []const u8, name: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}/{s}", .{ prefix, cellar_name, name }) catch return false;
    var d = std.fs.openDirAbsolute(path, .{}) catch return false;
    d.close();
    return true;
}

/// Remove a directory only if it is empty.
fn removeIfEmptyDir(path: []const u8) void {
    var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch return;
    var iter = dir.iterate();
    // If there's any entry, the directory is not empty.
    if ((iter.next() catch null) != null) {
        dir.close();
        return;
    }
    dir.close();
    std.fs.deleteTreeAbsolute(path) catch {};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "untapCmd compiles and has correct signature" {
    const handler: @import("../dispatch.zig").CommandFn = untapCmd;
    _ = handler;
}

test "parseTapName valid input" {
    const result = parseTapName("user/repo").?;
    try std.testing.expectEqualStrings("user", result.user);
    try std.testing.expectEqualStrings("repo", result.repo);
}

test "parseTapName with homebrew prefix" {
    const result = parseTapName("user/homebrew-repo").?;
    try std.testing.expectEqualStrings("user", result.user);
    try std.testing.expectEqualStrings("homebrew-repo", result.repo);
}

test "parseTapName rejects no slash" {
    try std.testing.expect(parseTapName("noslash") == null);
}

test "parseTapName rejects empty user" {
    try std.testing.expect(parseTapName("/repo") == null);
}

test "parseTapName rejects empty repo" {
    try std.testing.expect(parseTapName("user/") == null);
}

test "parseTapName rejects multiple slashes" {
    try std.testing.expect(parseTapName("a/b/c") == null);
}

test "removeIfEmptyDir does not crash on nonexistent path" {
    removeIfEmptyDir("/nonexistent/path/xyz");
}

test "isInstalledIn returns false for nonexistent path" {
    const result = isInstalledIn(std.testing.allocator, "/nonexistent", "Cellar", "fake");
    try std.testing.expect(!result);
}
