const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const Cellar = @import("../cellar.zig").Cellar;
const Index = @import("../index.zig").Index;
const Tab = @import("../tab.zig").Tab;

/// Show installed formulae that are not dependencies of any other installed formula.
///
/// For each installed formula, if it is NOT in the set of dependencies of any
/// other installed formula and was installed on request, its name is printed.
pub fn leavesCmd(allocator: Allocator, _: []const []const u8, config: Config) anyerror!void {
    // Load the formula index from disk or build from the JWS cache.
    var index = try Index.loadOrBuild(allocator, config.cache);
    // Note: do not call index.deinit() -- the index may be mmap'd (from disk)
    // in which case the allocator field is undefined. The process exits after
    // this command so OS reclamation is sufficient.
    _ = &index;

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

    // Build a set of all dependency names across every installed formula.
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

    // Print each installed formula that is not a dependency and was installed on request.
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const stdout = &w.interface;

    for (installed) |formula| {
        if (dep_set.contains(formula.name)) continue;

        // Build the keg path for the latest version to read the Tab.
        var path_buf: [1024]u8 = undefined;
        const keg_path = std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}", .{
            config.cellar,
            formula.name,
            formula.latestVersion(),
        }) catch continue;

        const tab = Tab.loadFromKeg(allocator, keg_path) orelse continue;
        defer tab.deinit(allocator);

        if (tab.installed_on_request) {
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
