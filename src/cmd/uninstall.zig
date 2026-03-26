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
    const raw_name = formula_name orelse {
        var err_buf: [4096]u8 = undefined;
        var ew = std.fs.File.stderr().writer(&err_buf);
        const stderr = &ew.interface;
        try stderr.print("Usage: bru uninstall <formula>\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    // Extract simple name from tap-prefixed names (e.g. "user/tap/pkg" -> "pkg").
    const name = if (std.mem.lastIndexOfScalar(u8, raw_name, '/')) |idx|
        raw_name[idx + 1 ..]
    else
        raw_name;

    const out = Output.init(config.no_color);
    const err_out = Output.initErr(config.no_color);

    // 3. Get installed versions — check cellar first, then caskroom.
    const cellar = Cellar.init(config.cellar);
    var base_path = config.cellar;
    var versions = cellar.installedVersions(allocator, name);
    if (versions == null) {
        const caskroom = Cellar.init(config.caskroom);
        versions = caskroom.installedVersions(allocator, name);
        if (versions != null) base_path = config.caskroom;
    }
    const installed_versions = versions orelse {
        err_out.err("{s} is not installed.", .{name});
        std.process.exit(1);
    };
    defer {
        for (installed_versions) |v| allocator.free(v);
        allocator.free(installed_versions);
    }

    // 4. Set up linker.
    var linker = Linker.init(allocator, config.prefix);

    // 5. For each version: unlink, then delete keg directory.
    for (installed_versions) |version| {
        var keg_buf: [fs.max_path_bytes]u8 = undefined;
        const keg_path = std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ base_path, name, version }) catch continue;

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
        const formula_dir = std.fmt.bufPrint(&formula_dir_buf, "{s}/{s}", .{ base_path, name }) catch "";
        if (formula_dir.len > 0) {
            fs.deleteDirAbsolute(formula_dir) catch {};
        }
    }

    // 7. Print completion section.
    const done_title = try std.fmt.allocPrint(allocator, "{s} is uninstalled", .{name});
    defer allocator.free(done_title);
    out.section(done_title);

    // Record uninstall in state history.
    {
        var state = @import("../state.zig").State.load(allocator);
        defer state.deinit();
        state.recordAction("uninstall", name, installed_versions[0], null) catch {};
        state.save() catch {};
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "uninstallCmd compiles and has correct signature" {
    // Smoke test: verifies the function signature is correct and the module compiles.
    const handler: @import("../dispatch.zig").CommandFn = uninstallCmd;
    _ = handler;
}
