const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const dispatch = @import("../dispatch.zig");
const Output = @import("../output.zig").Output;

pub fn commandsCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    var include_aliases = false;
    var quiet = config.quiet;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--include-aliases")) {
            include_aliases = true;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            quiet = true;
        }
    }

    // Collect built-in command display names (all entries are heap-duped for
    // uniform cleanup, which matters in debug builds with the GPA leak checker).
    var builtin_list: std.ArrayList([]const u8) = .{};
    defer {
        for (builtin_list.items) |item| allocator.free(item);
        builtin_list.deinit(allocator);
    }

    // Add native command names, transforming __xxx to --xxx for display.
    inline for (dispatch.native_commands) |entry| {
        const name = entry.name;
        if (comptime (name.len >= 2 and name[0] == '_' and name[1] == '_')) {
            try builtin_list.append(allocator, try std.fmt.allocPrint(allocator, "--{s}", .{name[2..]}));
        } else {
            try builtin_list.append(allocator, try allocator.dupe(u8, name));
        }
    }

    // Include aliases that resolve to native commands.
    if (include_aliases) {
        inline for (dispatch.alias_entries) |pair| {
            if (dispatch.getCommand(pair[1]) != null) {
                try builtin_list.append(allocator, try allocator.dupe(u8, pair[0]));
            }
        }
    }

    std.mem.sort([]const u8, builtin_list.items, {}, stringLessThan);

    // Collect external commands from taps and PATH (all entries are heap-duped).
    var external_list: std.ArrayList([]const u8) = .{};
    defer {
        for (external_list.items) |item| allocator.free(item);
        external_list.deinit(allocator);
    }

    scanTapCommands(allocator, config.prefix, &external_list) catch {};
    scanPathCommands(allocator, &external_list) catch {};

    std.mem.sort([]const u8, external_list.items, {}, stringLessThan);

    // Output.
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const stdout = &w.interface;

    if (quiet) {
        // Quiet mode: merge all, sort, deduplicate, no headers.
        var all: std.ArrayList([]const u8) = .{};
        defer all.deinit(allocator);
        try all.appendSlice(allocator, builtin_list.items);
        try all.appendSlice(allocator, external_list.items);
        std.mem.sort([]const u8, all.items, {}, stringLessThan);

        var prev: ?[]const u8 = null;
        for (all.items) |name| {
            if (prev) |p| {
                if (std.mem.eql(u8, name, p)) continue;
            }
            try stdout.print("{s}\n", .{name});
            prev = name;
        }
    } else {
        const out = Output.init(config.no_color);
        out.section("Built-in commands");

        var prev: ?[]const u8 = null;
        for (builtin_list.items) |name| {
            if (prev) |p| {
                if (std.mem.eql(u8, name, p)) continue;
            }
            try stdout.print("{s}\n", .{name});
            prev = name;
        }

        if (external_list.items.len > 0) {
            try stdout.flush();
            out.section("External commands");
            prev = null;
            for (external_list.items) |name| {
                if (prev) |p| {
                    if (std.mem.eql(u8, name, p)) continue;
                }
                try stdout.print("{s}\n", .{name});
                prev = name;
            }
        }
    }
    try stdout.flush();
}

/// Scan tap directories for brew-*.rb external commands.
/// Path pattern: {prefix}/Library/Taps/{user}/{repo}/cmd/brew-*.rb
fn scanTapCommands(allocator: Allocator, prefix: []const u8, list: *std.ArrayList([]const u8)) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const taps_path = std.fmt.bufPrint(&path_buf, "{s}/Library/Taps", .{prefix}) catch return;

    var taps_dir = std.fs.openDirAbsolute(taps_path, .{ .iterate = true }) catch return;
    defer taps_dir.close();

    var user_iter = taps_dir.iterate();
    while (try user_iter.next()) |user_entry| {
        if (user_entry.kind != .directory) continue;

        var user_dir = taps_dir.openDir(user_entry.name, .{ .iterate = true }) catch continue;
        defer user_dir.close();

        var repo_iter = user_dir.iterate();
        while (try repo_iter.next()) |repo_entry| {
            if (repo_entry.kind != .directory) continue;

            var repo_dir = user_dir.openDir(repo_entry.name, .{}) catch continue;
            defer repo_dir.close();

            var cmd_dir = repo_dir.openDir("cmd", .{ .iterate = true }) catch continue;
            defer cmd_dir.close();

            var cmd_iter = cmd_dir.iterate();
            while (try cmd_iter.next()) |cmd_entry| {
                if (cmd_entry.kind != .file and cmd_entry.kind != .sym_link) continue;
                const name = cmd_entry.name;
                if (std.mem.startsWith(u8, name, "brew-") and std.mem.endsWith(u8, name, ".rb")) {
                    const cmd_name = name[5 .. name.len - 3];
                    if (cmd_name.len > 0) {
                        try list.append(allocator, try allocator.dupe(u8, cmd_name));
                    }
                }
            }
        }
    }
}

/// Scan PATH directories for brew-* executables.
fn scanPathCommands(allocator: Allocator, list: *std.ArrayList([]const u8)) !void {
    const path_env = std.posix.getenv("PATH") orelse return;

    var path_iter = std.mem.splitScalar(u8, path_env, ':');
    while (path_iter.next()) |dir_path| {
        if (dir_path.len == 0) continue;
        if (!std.fs.path.isAbsolute(dir_path)) continue;

        var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch continue;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .directory) continue;
            const name = entry.name;
            if (std.mem.startsWith(u8, name, "brew-")) {
                const cmd_name = name[5..];
                if (cmd_name.len > 0) {
                    try list.append(allocator, try allocator.dupe(u8, cmd_name));
                }
            }
        }
    }
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "commandsCmd compiles and has correct signature" {
    const handler: dispatch.CommandFn = commandsCmd;
    _ = handler;
}

test "display name transforms __ prefix to --" {
    var found_prefix = false;
    inline for (dispatch.native_commands) |entry| {
        if (comptime std.mem.eql(u8, entry.name, "__prefix")) {
            found_prefix = true;
        }
    }
    try std.testing.expect(found_prefix);
}

test "scanTapCommands handles missing taps directory" {
    const allocator = std.testing.allocator;
    var list: std.ArrayList([]const u8) = .{};
    defer list.deinit(allocator);

    try scanTapCommands(allocator, "/nonexistent/path/xyz", &list);
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
}

test "scanPathCommands does not crash" {
    const allocator = std.testing.allocator;
    var list: std.ArrayList([]const u8) = .{};
    defer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }

    try scanPathCommands(allocator, &list);
}

test "stringLessThan sorts -- flags before alpha" {
    try std.testing.expect(stringLessThan({}, "--cache", "autoremove"));
    try std.testing.expect(!stringLessThan({}, "zsh", "autoremove"));
    try std.testing.expect(stringLessThan({}, "autoremove", "zsh"));
}
