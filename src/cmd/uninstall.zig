const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const Cellar = @import("../cellar.zig").Cellar;
const Linker = @import("../linker.zig").Linker;
const Output = @import("../output.zig").Output;

/// Uninstall a formula by unlinking it from the prefix and removing its keg.
///
/// Usage: bru uninstall [--force/-f] <formula>
///
/// Removes all installed versions of the given formula from the Cellar,
/// first unlinking symlinks from the prefix, then deleting the keg
/// directories.
pub fn uninstallCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    // 1. Parse args -- support --force/-f flag and formula name.
    //    Note: --force is accepted but not acted on yet (no dependency checks).
    var formula_name: ?[]const u8 = null;

    for (args) |arg| {
        if (arg.len > 0 and arg[0] == '-') continue;
        if (formula_name == null) {
            formula_name = arg;
        }
    }

    // 2. If no formula name, print usage and exit(1).
    const name = formula_name orelse {
        var err_buf: [4096]u8 = undefined;
        var ew = std.fs.File.stderr().writer(&err_buf);
        const stderr = &ew.interface;
        try stderr.print("Usage: bru uninstall <formula>\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    const out = Output.init(config.no_color);
    const err_out = Output.initErr(config.no_color);

    // 3. Get installed versions via cellar.
    const cellar = Cellar.init(config.cellar);
    const versions = cellar.installedVersions(allocator, name) orelse {
        err_out.err("{s} is not installed.", .{name});
        std.process.exit(1);
    };
    defer {
        for (versions) |v| allocator.free(v);
        allocator.free(versions);
    }

    // 4. Set up linker.
    var linker = Linker.init(allocator, config.prefix);

    // 5. For each version: unlink, then delete keg directory.
    for (versions) |version| {
        var keg_buf: [fs.max_path_bytes]u8 = undefined;
        const keg_path = std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ config.cellar, name, version }) catch continue;

        out.print("Uninstalling {s} {s}...\n", .{ name, version });

        // Unlink symlinks from prefix (catch and warn on error, don't fail).
        linker.unlink(keg_path) catch |link_err| {
            out.warn("Failed to unlink {s} {s}: {s}", .{ name, version, @errorName(link_err) });
        };

        // Delete the keg directory tree.
        fs.deleteTreeAbsolute(keg_path) catch |del_err| {
            err_out.err("Could not remove {s}/{s}: {s}", .{ name, version, @errorName(del_err) });
        };
    }

    // 6. Try to remove the formula directory if empty.
    {
        var formula_dir_buf: [fs.max_path_bytes]u8 = undefined;
        const formula_dir = std.fmt.bufPrint(&formula_dir_buf, "{s}/{s}", .{ config.cellar, name }) catch "";
        if (formula_dir.len > 0) {
            fs.deleteDirAbsolute(formula_dir) catch {};
        }
    }

    // 7. Print completion section.
    const done_title = try std.fmt.allocPrint(allocator, "{s} is uninstalled", .{name});
    defer allocator.free(done_title);
    out.section(done_title);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "uninstallCmd compiles and has correct signature" {
    // Smoke test: verifies the function signature is correct and the module compiles.
    const handler: @import("../dispatch.zig").CommandFn = uninstallCmd;
    _ = handler;
}
