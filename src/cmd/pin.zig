const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const Cellar = @import("../cellar.zig").Cellar;
const Output = @import("../output.zig").Output;

/// Pin a formula to prevent it from being upgraded.
///
/// Usage: bru pin <formula>
///
/// Creates a symlink at {prefix}/var/homebrew/pinned/{formula} pointing to
/// the formula's latest installed keg, matching Homebrew's pin mechanism.
/// No output on success (matches brew behavior).
pub fn pinCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    const err_out = Output.initErr(config.no_color);

    // Collect formula names (skip flags).
    var names: std.ArrayList([]const u8) = .{};
    defer names.deinit(allocator);

    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) continue;
        try names.append(allocator, arg);
    }

    if (names.items.len == 0) {
        err_out.err("This command requires a formula argument.", .{});
        std.process.exit(1);
    }

    const cellar = Cellar.init(config.cellar);

    for (names.items) |name| {
        // Validate the formula is installed.
        if (!cellar.isInstalled(name)) {
            err_out.err("{s} is not installed.", .{name});
            std.process.exit(1);
        }

        // Find the latest installed version to create the symlink target.
        const versions = cellar.installedVersions(allocator, name) orelse {
            err_out.err("{s} is not installed.", .{name});
            std.process.exit(1);
        };
        defer {
            for (versions) |v| allocator.free(v);
            allocator.free(versions);
        }

        // Pick the latest version (semantically highest).
        const latest = blk: {
            const PkgVersion = @import("../version.zig").PkgVersion;
            var best = versions[0];
            for (versions[1..]) |v| {
                if (PkgVersion.parse(v).order(PkgVersion.parse(best)) == .gt) best = v;
            }
            break :blk best;
        };

        // Build the pinned kegs directory path: {prefix}/var/homebrew/pinned
        var pinned_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const pinned_dir = std.fmt.bufPrint(&pinned_dir_buf, "{s}/var/homebrew/pinned", .{config.prefix}) catch {
            err_out.err("Path too long.", .{});
            std.process.exit(1);
        };

        // Ensure the pinned directory exists.
        std.fs.makeDirAbsolute(pinned_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => {
                // Try creating parent directories too.
                makeDirRecursive(pinned_dir) catch {
                    err_out.err("Could not create pinned directory: {s}", .{pinned_dir});
                    std.process.exit(1);
                };
            },
        };

        // Build the symlink path: {prefix}/var/homebrew/pinned/{name}
        var pin_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const pin_path = std.fmt.bufPrint(&pin_path_buf, "{s}/{s}", .{ pinned_dir, name }) catch {
            err_out.err("Path too long.", .{});
            std.process.exit(1);
        };

        // Build the target keg path: {cellar}/{name}/{version}
        var keg_buf: [std.fs.max_path_bytes]u8 = undefined;
        const keg_path = std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ config.cellar, name, latest }) catch {
            err_out.err("Path too long.", .{});
            std.process.exit(1);
        };

        // Check if already pinned.
        if (isSymlink(pin_path)) {
            // Already pinned — silently succeed (matches brew behavior).
            continue;
        }

        // Create the symlink.
        std.posix.symlink(keg_path, pin_path) catch {
            err_out.err("Could not pin {s}.", .{name});
            std.process.exit(1);
        };
    }
}

/// Check whether a formula is pinned by looking for a symlink in the pinned directory.
pub fn isPinned(prefix: []const u8, name: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const pin_path = std.fmt.bufPrint(&buf, "{s}/var/homebrew/pinned/{s}", .{ prefix, name }) catch return false;
    return isSymlink(pin_path);
}

/// Check whether a path is a symlink.
fn isSymlink(path: []const u8) bool {
    const stat = std.fs.cwd().statFile(path) catch return false;
    _ = stat;
    // statFile follows symlinks — use lstat instead to detect the symlink itself.
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = std.fs.cwd().readLink(path, &link_buf) catch return false;
    return true;
}

/// Recursively create directories for a path.
fn makeDirRecursive(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |e| switch (e) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            // Parent doesn't exist — create it first.
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

test "pinCmd compiles and has correct signature" {
    const handler: @import("../dispatch.zig").CommandFn = pinCmd;
    _ = handler;
}

test "isPinned returns false for nonexistent formula" {
    const result = isPinned(Config.default_prefix, "__nonexistent_formula_xyz_42__");
    try std.testing.expect(!result);
}

test "isSymlink returns false for nonexistent path" {
    const result = isSymlink("/nonexistent/path/__xyz__");
    try std.testing.expect(!result);
}
