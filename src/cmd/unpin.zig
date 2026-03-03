const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const Cellar = @import("../cellar.zig").Cellar;
const Output = @import("../output.zig").Output;
const isPinned = @import("pin.zig").isPinned;

/// Unpin a formula to allow it to be upgraded again.
///
/// Usage: bru unpin <formula>
///
/// Removes the symlink at {prefix}/var/homebrew/pinned/{formula}.
/// No output on success (matches brew behavior).
pub fn unpinCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
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

        // Validate the formula is currently pinned.
        if (!isPinned(config.prefix, name)) {
            err_out.err("{s} is not pinned.", .{name});
            std.process.exit(1);
        }

        // Build the pin symlink path: {prefix}/var/homebrew/pinned/{name}
        var pin_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const pin_path = std.fmt.bufPrint(&pin_path_buf, "{s}/var/homebrew/pinned/{s}", .{ config.prefix, name }) catch {
            err_out.err("Path too long.", .{});
            std.process.exit(1);
        };

        // Remove the symlink.
        std.fs.cwd().deleteFile(pin_path) catch {
            err_out.err("Could not unpin {s}.", .{name});
            std.process.exit(1);
        };
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "unpinCmd compiles and has correct signature" {
    const handler: @import("../dispatch.zig").CommandFn = unpinCmd;
    _ = handler;
}
