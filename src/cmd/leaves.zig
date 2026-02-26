const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const Cellar = @import("../cellar.zig").Cellar;
const Index = @import("../index.zig").Index;
const Tab = @import("../tab.zig").Tab;
const writeJsonStr = @import("../json_helpers.zig").writeJsonStr;

/// Show installed formulae that are not dependencies of any other installed formula.
///
/// For each installed formula, if it is NOT in the set of dependencies of any
/// other installed formula and was installed on request, its name is printed.
pub fn leavesCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    var json_output = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        }
    }

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

    if (json_output) {
        try stdout.writeAll("[");
        var first: bool = true;
        for (installed) |formula| {
            if (dep_set.contains(formula.name)) continue;

            var path_buf: [1024]u8 = undefined;
            const keg_path = std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}", .{
                config.cellar,
                formula.name,
                formula.latestVersion(),
            }) catch continue;

            const tab = Tab.loadFromKeg(allocator, keg_path) orelse continue;
            defer tab.deinit(allocator);

            if (tab.installed_on_request) {
                const display_name = getDisplayName(&index, formula.name);
                if (!first) try stdout.writeAll(",");
                try writeJsonStr(stdout, display_name);
                first = false;
            }
        }
        try stdout.writeAll("]\n");
        try stdout.flush();
        return;
    }

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
            const display_name = getDisplayName(&index, formula.name);
            try stdout.print("{s}\n", .{display_name});
        }
    }

    try stdout.flush();
}

/// Resolve display name: use full_name from index if it's a non-core tap, otherwise short name.
fn getDisplayName(index: *const Index, name: []const u8) []const u8 {
    const entry = index.lookup(name) orelse return name;
    const full = index.getString(entry.full_name_offset);
    if (full.len > 0 and !std.mem.startsWith(u8, full, "homebrew/core/")) {
        return full;
    }
    return name;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "leavesCmd compiles and has correct signature" {
    // Smoke test: verifies the function signature is correct and the module compiles.
    const handler: @import("../dispatch.zig").CommandFn = leavesCmd;
    _ = handler;
}
