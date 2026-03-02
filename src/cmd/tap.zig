const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const Output = @import("../output.zig").Output;

/// Manage third-party formula repositories (taps).
///
/// Usage: bru tap                       List installed taps
///        bru tap user/repo [URL]       Add a tap
///
/// Options:
///   --shallow  Shallow clone (--depth=1)
///   --force    Force re-clone of an existing tap
pub fn tapCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    var shallow = false;
    var force = false;
    var positionals: [2]?[]const u8 = .{ null, null };
    var pos_count: usize = 0;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--shallow")) {
            shallow = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (pos_count < 2) {
                positionals[pos_count] = arg;
                pos_count += 1;
            }
        }
    }

    if (positionals[0] == null) {
        try listTaps(allocator, config);
        return;
    }

    try addTap(allocator, positionals[0].?, positionals[1], shallow, force, config);
}

/// List all installed taps by scanning the Taps directory.
fn listTaps(allocator: Allocator, config: Config) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const taps_path = std.fmt.bufPrint(&path_buf, "{s}/Library/Taps", .{config.repository}) catch return;

    var taps_dir = std.fs.openDirAbsolute(taps_path, .{ .iterate = true }) catch return;
    defer taps_dir.close();

    var list = std.ArrayList([]const u8){};
    defer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }

    var user_iter = taps_dir.iterate();
    while (try user_iter.next()) |user_entry| {
        if (user_entry.kind != .directory) continue;
        if (std.mem.startsWith(u8, user_entry.name, ".")) continue;

        var user_dir = taps_dir.openDir(user_entry.name, .{ .iterate = true }) catch continue;
        defer user_dir.close();

        var repo_iter = user_dir.iterate();
        while (try repo_iter.next()) |repo_entry| {
            if (repo_entry.kind != .directory) continue;
            if (std.mem.startsWith(u8, repo_entry.name, ".")) continue;

            const repo_display = if (std.mem.startsWith(u8, repo_entry.name, "homebrew-"))
                repo_entry.name["homebrew-".len..]
            else
                repo_entry.name;

            const tap_name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ user_entry.name, repo_display });
            try list.append(allocator, tap_name);
        }
    }

    std.mem.sort([]const u8, list.items, {}, stringLessThan);

    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const stdout = &w.interface;
    for (list.items) |name| {
        try stdout.print("{s}\n", .{name});
    }
    try stdout.flush();
}

/// Parse "user/repo" into components. Returns null for invalid format.
fn parseTapName(tap: []const u8) ?struct { user: []const u8, repo: []const u8 } {
    const slash = std.mem.indexOfScalar(u8, tap, '/') orelse return null;
    if (slash == 0 or slash + 1 >= tap.len) return null;
    if (std.mem.indexOfScalarPos(u8, tap, slash + 1, '/') != null) return null;
    return .{ .user = tap[0..slash], .repo = tap[slash + 1 ..] };
}

/// Clone a tap repository into the Homebrew taps directory.
fn addTap(
    allocator: Allocator,
    tap_arg: []const u8,
    custom_url: ?[]const u8,
    shallow: bool,
    force: bool,
    config: Config,
) !void {
    const err_out = Output.initErr(config.no_color);
    const out = Output.init(config.no_color);

    const parsed = parseTapName(tap_arg) orelse {
        err_out.err("Invalid tap name \"{s}\". Expected format: user/repo", .{tap_arg});
        std.process.exit(1);
    };

    // Directory name always has "homebrew-" prefix.
    var repo_dir_buf: [256]u8 = undefined;
    const repo_dir_name = if (std.mem.startsWith(u8, parsed.repo, "homebrew-"))
        parsed.repo
    else
        std.fmt.bufPrint(&repo_dir_buf, "homebrew-{s}", .{parsed.repo}) catch {
            err_out.err("Repository name too long", .{});
            std.process.exit(1);
        };

    // Display name never has "homebrew-" prefix.
    const display_repo = if (std.mem.startsWith(u8, parsed.repo, "homebrew-"))
        parsed.repo["homebrew-".len..]
    else
        parsed.repo;

    var tap_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tap_path = std.fmt.bufPrint(&tap_path_buf, "{s}/Library/Taps/{s}/{s}", .{
        config.repository, parsed.user, repo_dir_name,
    }) catch {
        err_out.err("Tap path too long", .{});
        std.process.exit(1);
    };

    // Check if already tapped.
    const already_tapped = blk: {
        var dir = std.fs.openDirAbsolute(tap_path, .{}) catch break :blk false;
        dir.close();
        break :blk true;
    };

    if (already_tapped and !force) {
        out.print("{s}/{s} is already tapped.\n", .{ parsed.user, display_repo });
        out.print("To force-clone, run: bru tap --force {s}/{s}\n", .{ parsed.user, display_repo });
        return;
    }

    // Remove existing tap if --force.
    if (already_tapped and force) {
        std.fs.deleteTreeAbsolute(tap_path) catch |err| {
            err_out.err("Failed to remove existing tap: {s}", .{@errorName(err)});
            std.process.exit(1);
        };
    }

    var url_buf: [1024]u8 = undefined;
    const clone_url = custom_url orelse
        std.fmt.bufPrint(&url_buf, "https://github.com/{s}/{s}", .{ parsed.user, repo_dir_name }) catch {
            err_out.err("URL too long", .{});
            std.process.exit(1);
        };

    var msg_buf: [256]u8 = undefined;
    const section_msg = std.fmt.bufPrint(&msg_buf, "Tapping {s}/{s}", .{ parsed.user, display_repo }) catch "Tapping";
    out.section(section_msg);

    // Ensure parent directory exists.
    var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
    const parent_path = std.fmt.bufPrint(&parent_buf, "{s}/Library/Taps/{s}", .{
        config.repository, parsed.user,
    }) catch {
        err_out.err("Path too long", .{});
        std.process.exit(1);
    };
    std.fs.cwd().makePath(parent_path) catch |err| {
        err_out.err("Failed to create directory {s}: {s}", .{ parent_path, @errorName(err) });
        std.process.exit(1);
    };

    // Build git clone argv.
    var argv_buf: [5][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = "git";
    argc += 1;
    argv_buf[argc] = "clone";
    argc += 1;
    if (shallow) {
        argv_buf[argc] = "--depth=1";
        argc += 1;
    }
    argv_buf[argc] = clone_url;
    argc += 1;
    argv_buf[argc] = tap_path;
    argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    const term = child.spawnAndWait() catch {
        err_out.err("Failed to run git. Is git installed?", .{});
        std.process.exit(1);
    };

    switch (term) {
        .Exited => |code| {
            if (code != 0) std.process.exit(1);
        },
        else => std.process.exit(1),
    }

    // Count formulae and casks in the new tap.
    const counts = countTapContents(tap_path);
    const f_label: []const u8 = if (counts.formulae == 1) "formula" else "formulae";
    const c_label: []const u8 = if (counts.casks == 1) "cask" else "casks";

    var summary_buf: [256]u8 = undefined;
    const summary = if (counts.formulae > 0 and counts.casks > 0)
        std.fmt.bufPrint(&summary_buf, "Tapped {d} {s} and {d} {s} ({s}/{s})", .{
            counts.formulae, f_label, counts.casks, c_label, parsed.user, display_repo,
        }) catch "Tapped"
    else if (counts.formulae > 0)
        std.fmt.bufPrint(&summary_buf, "Tapped {d} {s} ({s}/{s})", .{
            counts.formulae, f_label, parsed.user, display_repo,
        }) catch "Tapped"
    else if (counts.casks > 0)
        std.fmt.bufPrint(&summary_buf, "Tapped {d} {s} ({s}/{s})", .{
            counts.casks, c_label, parsed.user, display_repo,
        }) catch "Tapped"
    else
        std.fmt.bufPrint(&summary_buf, "Tapped {s}/{s}", .{
            parsed.user, display_repo,
        }) catch "Tapped";

    out.section(summary);
}

/// Count formula and cask .rb files in a tap directory.
fn countTapContents(tap_path: []const u8) struct { formulae: usize, casks: usize } {
    return .{
        .formulae = countRbFiles(tap_path, "Formula"),
        .casks = countRbFiles(tap_path, "Casks"),
    };
}

/// Count .rb files in a subdirectory, handling both flat and sharded layouts.
fn countRbFiles(tap_path: []const u8, subdir: []const u8) usize {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ tap_path, subdir }) catch return 0;

    var dir = std.fs.openDirAbsolute(full_path, .{ .iterate = true }) catch return 0;
    defer dir.close();

    var count: usize = 0;
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".rb")) {
            count += 1;
        } else if (entry.kind == .directory and entry.name.len == 1) {
            // Sharded layout: Formula/a/formula.rb
            var sub_dir = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
            defer sub_dir.close();
            var sub_iter = sub_dir.iterate();
            while (sub_iter.next() catch null) |sub_entry| {
                if (sub_entry.kind == .file and std.mem.endsWith(u8, sub_entry.name, ".rb")) {
                    count += 1;
                }
            }
        }
    }
    return count;
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "tapCmd compiles and has correct signature" {
    const handler: @import("../dispatch.zig").CommandFn = tapCmd;
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

test "countRbFiles returns zero for nonexistent path" {
    const count = countRbFiles("/nonexistent/path/xyz", "Formula");
    try std.testing.expectEqual(@as(usize, 0), count);
}
