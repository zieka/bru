const std = @import("std");
const Config = @import("../config.zig").Config;
const Output = @import("../output.zig").Output;

// Embedded completion scripts (comptime).
const bash_completion = @embedFile("completions/bru.bash");
const zsh_completion = @embedFile("completions/bru.zsh");
const fish_completion = @embedFile("completions/bru.fish");

const ShellTarget = struct {
    dir_suffix: []const u8,
    filename: []const u8,
    content: []const u8,
};

const shell_targets = [_]ShellTarget{
    .{ .dir_suffix = "/etc/bash_completion.d", .filename = "bru", .content = bash_completion },
    .{ .dir_suffix = "/share/zsh/site-functions", .filename = "_bru", .content = zsh_completion },
    .{ .dir_suffix = "/share/fish/vendor_completions.d", .filename = "bru.fish", .content = fish_completion },
};

pub fn completionsCmd(_: std.mem.Allocator, args: []const []const u8, config: Config) anyerror!void {
    const out = Output.init(config.no_color);
    const err_out = Output.initErr(config.no_color);

    // Find first positional arg (skip flags).
    var subcmd: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) continue;
        subcmd = arg;
        break;
    }

    const cmd = subcmd orelse "state";

    if (std.mem.eql(u8, cmd, "state")) {
        return showState(out, config.prefix);
    } else if (std.mem.eql(u8, cmd, "link")) {
        return doLink(out, err_out, config.prefix);
    } else if (std.mem.eql(u8, cmd, "unlink")) {
        return doUnlink(out, config.prefix);
    } else {
        err_out.err("Unknown subcommand: {s}", .{cmd});
        err_out.print("Usage: bru completions [state|link|unlink]", .{});
        std.process.exit(1);
    }
}

fn showState(out: Output, prefix: []const u8) void {
    var all_linked = true;
    for (shell_targets) |target| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}{s}/{s}", .{ prefix, target.dir_suffix, target.filename }) catch continue;

        if (!fileExists(path)) all_linked = false;
    }

    if (all_linked) {
        out.print("Completions are linked.\n", .{});
    } else {
        out.print("Completions are not linked.\n", .{});
    }
}

fn doLink(out: Output, err_out: Output, prefix: []const u8) void {
    for (shell_targets) |target| {
        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = std.fmt.bufPrint(&dir_buf, "{s}{s}", .{ prefix, target.dir_suffix }) catch {
            err_out.err("Path too long.", .{});
            std.process.exit(1);
        };

        // Create the directory if it doesn't exist.
        makeDirRecursive(dir) catch {
            err_out.err("Could not create directory: {s}", .{dir});
            std.process.exit(1);
        };

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, target.filename }) catch {
            err_out.err("Path too long.", .{});
            std.process.exit(1);
        };

        // Write the file (overwrites if already present).
        const cwd = std.fs.cwd();
        const file = cwd.createFile(path, .{}) catch {
            err_out.err("Could not write {s}", .{path});
            std.process.exit(1);
        };
        defer file.close();
        file.writeAll(target.content) catch {
            err_out.err("Could not write {s}", .{path});
            std.process.exit(1);
        };
    }

    out.print("Completions linked successfully.\n", .{});
}

fn doUnlink(out: Output, prefix: []const u8) void {
    for (shell_targets) |target| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}{s}/{s}", .{ prefix, target.dir_suffix, target.filename }) catch continue;

        std.fs.cwd().deleteFile(path) catch {};
    }

    out.print("Completions unlinked.\n", .{});
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Recursively create directories for a path.
fn makeDirRecursive(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |e| switch (e) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            const parent = std.fs.path.dirname(path) orelse return e;
            try makeDirRecursive(parent);
            std.fs.makeDirAbsolute(path) catch |e2| switch (e2) {
                error.PathAlreadyExists => return,
                else => return e2,
            };
        },
        else => return e,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "completionsCmd compiles and has correct signature" {
    const handler: @import("../dispatch.zig").CommandFn = completionsCmd;
    _ = handler;
}

test "embedded completion scripts are non-empty" {
    try std.testing.expect(bash_completion.len > 0);
    try std.testing.expect(zsh_completion.len > 0);
    try std.testing.expect(fish_completion.len > 0);
}

test "fileExists returns false for nonexistent path" {
    try std.testing.expect(!fileExists("/nonexistent/__bru_test_xyz__"));
}
