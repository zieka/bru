const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Config = @import("../config.zig").Config;
const Cellar = @import("../cellar.zig").Cellar;
const Tab = @import("../tab.zig").Tab;
const writeJsonStr = @import("../json_helpers.zig").writeJsonStr;

/// Show installed formulae that are not dependencies of any other installed formula.
///
/// For each installed formula, if it is NOT in the set of runtime dependencies
/// of any other installed formula, its name is printed (with tap prefix for
/// non-homebrew/core taps). Supports --json for JSON array output.
pub fn leavesCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    var json_output = false;
    for (args) |arg| {
        if (mem.eql(u8, arg, "--json")) {
            json_output = true;
        }
    }

    // Get all installed formulae from the cellar.
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

    // Build a set of all dependency names by reading each formula's
    // INSTALL_RECEIPT.json runtime_dependencies. This is more accurate than the
    // index because it reflects the actual installed dependency graph and works
    // for formulae from any tap, not just homebrew/core.
    //
    // We also cache each formula's source_tap from its Tab so we don't have to
    // re-read the receipt in the display loop.
    var dep_set = std.StringHashMap(void).init(allocator);
    defer {
        var it = dep_set.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        dep_set.deinit();
    }

    var tap_map = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = tap_map.valueIterator();
        while (it.next()) |val| allocator.free(val.*);
        tap_map.deinit();
    }

    for (installed) |formula| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const keg_path = std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}", .{
            config.cellar,
            formula.name,
            formula.latestVersion(),
        }) catch continue;

        const tab = Tab.loadFromKeg(allocator, keg_path) orelse continue;
        defer tab.deinit(allocator);

        for (tab.runtime_dependencies) |dep| {
            if (!dep_set.contains(dep.full_name)) {
                const duped = allocator.dupe(u8, dep.full_name) catch continue;
                dep_set.put(duped, {}) catch {
                    allocator.free(duped);
                    continue;
                };
            }
        }

        // Cache source_tap for the display loop.
        if (tab.source_tap.len > 0 and !mem.eql(u8, tab.source_tap, "homebrew/core")) {
            const duped_tap = allocator.dupe(u8, tab.source_tap) catch continue;
            tap_map.put(formula.name, duped_tap) catch {
                allocator.free(duped_tap);
                continue;
            };
        }
    }

    // Print each installed formula that is not a dependency of another formula.
    // Use tap-prefixed names for formulae from non-homebrew/core taps.
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const stdout = &w.interface;

    if (json_output) {
        try stdout.writeAll("[");
        var first: bool = true;
        for (installed) |formula| {
            if (dep_set.contains(formula.name)) continue;

            if (!first) try stdout.writeAll(",");
            if (tap_map.get(formula.name)) |tap| {
                var name_buf: [1024]u8 = undefined;
                const display_name = std.fmt.bufPrint(&name_buf, "{s}/{s}", .{ tap, formula.name }) catch continue;
                try writeJsonStr(stdout, display_name);
            } else {
                try writeJsonStr(stdout, formula.name);
            }
            first = false;
        }
        try stdout.writeAll("]\n");
        try stdout.flush();
        return;
    }

    for (installed) |formula| {
        if (dep_set.contains(formula.name)) continue;

        if (tap_map.get(formula.name)) |tap| {
            try stdout.print("{s}/{s}\n", .{ tap, formula.name });
        } else {
            try stdout.print("{s}\n", .{formula.name});
        }
    }

    try stdout.flush();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "leavesCmd compiles and has correct signature" {
    // Smoke test: verifies the function signature is correct and the module compiles.
    const handler: @import("../dispatch.zig").CommandFn = leavesCmd;
    _ = handler;
}
