const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const Cellar = @import("../cellar.zig").Cellar;
const Index = @import("../index.zig").Index;
const Tab = @import("../tab.zig").Tab;
const Linker = @import("../linker.zig").Linker;
const Output = @import("../output.zig").Output;

/// Uninstall orphaned dependencies that are no longer needed.
///
/// Usage: bru autoremove [--dry-run/-n]
///
/// A formula is considered an orphan if:
///   - It was NOT installed on request (i.e. it was pulled in as a dependency)
///   - No other installed formula depends on it
///
/// With --dry-run, only prints what would be removed without making changes.
pub fn autoremoveCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    // 1. Parse flags.
    var dry_run = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run") or std.mem.eql(u8, arg, "-n")) {
            dry_run = true;
        }
    }

    const out = Output.init(config.no_color);

    // 2. Load the formula index and get all installed formulae.
    var index = try Index.loadOrBuild(allocator, config.cache);
    _ = &index;

    const cellar = Cellar.init(config.cellar);
    const installed = cellar.installedFormulae(allocator);
    defer {
        for (installed) |f| {
            for (f.versions) |v| allocator.free(v);
            allocator.free(f.versions);
            allocator.free(f.name);
        }
        allocator.free(installed);
    }

    // 3. Build a set of all dependency names across every installed formula.
    var dep_set = std.StringHashMap(void).init(allocator);
    defer dep_set.deinit();

    for (installed) |formula| {
        const entry = index.lookup(formula.name) orelse continue;
        const deps = index.getStringList(allocator, entry.deps_offset) catch continue;
        defer allocator.free(deps);

        for (deps) |dep| {
            dep_set.put(dep, {}) catch {};
        }
    }

    // 4. Find orphans: not depended on by anyone AND not installed on request.
    var removed: u32 = 0;

    for (installed) |formula| {
        // If another installed formula depends on this one, it is not an orphan.
        if (dep_set.contains(formula.name)) continue;

        // Check the tab to see if it was installed on request.
        var path_buf: [fs.max_path_bytes]u8 = undefined;
        const keg_path = std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}", .{
            config.cellar,
            formula.name,
            formula.latestVersion(),
        }) catch continue;

        const tab = Tab.loadFromKeg(allocator, keg_path) orelse continue;
        defer tab.deinit(allocator);

        // If it was installed on request, it is not an orphan.
        if (tab.installed_on_request) continue;

        // 5. This formula is an orphan -- remove it.
        if (dry_run) {
            out.print("Would remove: {s}\n", .{formula.name});
        } else {
            out.print("Removing: {s}...\n", .{formula.name});

            // Unlink symlinks from prefix for each version.
            var linker = Linker.init(allocator, config.prefix);
            for (formula.versions) |version| {
                var ver_buf: [fs.max_path_bytes]u8 = undefined;
                const ver_path = std.fmt.bufPrint(&ver_buf, "{s}/{s}/{s}", .{
                    config.cellar,
                    formula.name,
                    version,
                }) catch continue;

                linker.unlink(ver_path) catch {};
            }

            // Delete each keg directory.
            for (formula.versions) |version| {
                var ver_buf: [fs.max_path_bytes]u8 = undefined;
                const ver_path = std.fmt.bufPrint(&ver_buf, "{s}/{s}/{s}", .{
                    config.cellar,
                    formula.name,
                    version,
                }) catch continue;

                fs.deleteTreeAbsolute(ver_path) catch |err| {
                    const err_out = Output.initErr(config.no_color);
                    err_out.err("Could not remove {s}: {s}", .{ ver_path, @errorName(err) });
                };
            }

            // Try to remove the formula directory if empty.
            {
                var formula_dir_buf: [fs.max_path_bytes]u8 = undefined;
                const formula_dir = std.fmt.bufPrint(&formula_dir_buf, "{s}/{s}", .{
                    config.cellar,
                    formula.name,
                }) catch "";
                if (formula_dir.len > 0) {
                    fs.deleteDirAbsolute(formula_dir) catch {};
                }
            }

            // Remove opt link.
            {
                var opt_buf: [fs.max_path_bytes]u8 = undefined;
                const opt_path = std.fmt.bufPrint(&opt_buf, "{s}/opt/{s}", .{
                    config.prefix,
                    formula.name,
                }) catch "";
                if (opt_path.len > 0) {
                    fs.deleteFileAbsolute(opt_path) catch {};
                }
            }
        }

        removed += 1;
    }

    // 6. Print summary.
    if (removed == 0) {
        out.print("No orphaned dependencies to remove.\n", .{});
    } else if (dry_run) {
        out.print("{d} orphaned {s} would be removed.\n", .{
            removed,
            if (removed == 1) @as([]const u8, "package") else @as([]const u8, "packages"),
        });
    } else {
        out.section("Autoremove complete");
        out.print("Removed {d} orphaned {s}.\n", .{
            removed,
            if (removed == 1) @as([]const u8, "package") else @as([]const u8, "packages"),
        });
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "autoremoveCmd compiles and has correct signature" {
    // Smoke test: verifies the function signature is correct and the module compiles.
    const handler: @import("../dispatch.zig").CommandFn = autoremoveCmd;
    _ = handler;
}
