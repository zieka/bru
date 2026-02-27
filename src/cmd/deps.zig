const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const Index = @import("../index.zig").Index;
const Output = @import("../output.zig").Output;
const writeJsonStr = @import("../json_helpers.zig").writeJsonStr;
const fuzzy = @import("../fuzzy.zig");

/// List dependencies for a formula.
///
/// Usage: bru deps [--include-build] [--tree] [--1|--direct] <formula>
///
/// By default, prints the full transitive closure of runtime dependencies
/// (sorted alphabetically, one per line), matching `brew deps` behaviour.
///
/// Flags:
///   --include-build   Also include build-time dependencies.
///   --tree            Print dependencies as an indented tree.
///   --1 / --direct    Show only direct (non-transitive) dependencies.
pub fn depsCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    var include_build = false;
    var tree_mode = false;
    var direct_only = false;
    var json_output = false;
    var formula_name: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--include-build")) {
            include_build = true;
        } else if (std.mem.eql(u8, arg, "--tree")) {
            tree_mode = true;
        } else if (std.mem.eql(u8, arg, "--1") or std.mem.eql(u8, arg, "--direct")) {
            direct_only = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (formula_name == null) {
                formula_name = arg;
            }
        }
    }

    if (tree_mode and json_output) {
        var warn_buf: [4096]u8 = undefined;
        var ww = std.fs.File.stderr().writer(&warn_buf);
        const warn_w = &ww.interface;
        try warn_w.print("Warning: --tree is ignored when --json is specified\n", .{});
        try warn_w.flush();
        tree_mode = false;
    }

    if (formula_name == null) {
        var err_buf: [4096]u8 = undefined;
        var ew = std.fs.File.stderr().writer(&err_buf);
        const stderr = &ew.interface;
        try stderr.print("Usage: bru deps [--include-build] [--tree] [--1|--direct] <formula>\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    var idx = try Index.loadOrBuild(allocator, config.cache);
    // Note: do not call idx.deinit() -- the index may be mmap'd (from disk)
    // in which case the allocator field is undefined. The process exits after
    // this command so OS reclamation is sufficient.

    const entry = idx.lookup(formula_name.?) orelse {
        const err_out = Output.initErr(config.no_color);
        err_out.err("No available formula with the name \"{s}\".", .{formula_name.?});
        const similar = fuzzy.findSimilar(&idx, allocator, formula_name.?, 3, 3) catch &.{};
        defer if (similar.len > 0) allocator.free(similar);
        if (similar.len > 0) {
            err_out.print("Did you mean?\n", .{});
            for (similar) |s| err_out.print("  {s}\n", .{s});
        }
        std.process.exit(1);
    };

    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const stdout = &w.interface;

    // --json: emit a flat JSON array of dependency strings
    if (json_output) {
        if (direct_only) {
            // Direct deps only
            const deps = try idx.getStringList(allocator, entry.deps_offset);
            defer allocator.free(deps);

            var bdeps: []const []const u8 = &.{};
            if (include_build) {
                bdeps = try idx.getStringList(allocator, entry.build_deps_offset);
            }
            defer if (include_build) allocator.free(bdeps);

            try stdout.writeAll("[");
            var first: bool = true;
            for (deps) |dep| {
                if (!first) try stdout.writeAll(",");
                try writeJsonStr(stdout, dep);
                first = false;
            }
            for (bdeps) |dep| {
                if (!first) try stdout.writeAll(",");
                try writeJsonStr(stdout, dep);
                first = false;
            }
            try stdout.writeAll("]\n");
        } else {
            // Transitive closure (tree mode + json also uses flat array)
            var visited = std.StringHashMap(void).init(allocator);
            defer visited.deinit();

            var result = std.ArrayList([]const u8){};
            defer result.deinit(allocator);

            try collectTransitiveDeps(&idx, allocator, formula_name.?, &visited, &result, include_build);

            std.mem.sort([]const u8, result.items, {}, stringLessThan);

            try stdout.writeAll("[");
            for (result.items, 0..) |dep, i| {
                if (i > 0) try stdout.writeAll(",");
                try writeJsonStr(stdout, dep);
            }
            try stdout.writeAll("]\n");
        }
        try stdout.flush();
        return;
    }

    if (tree_mode) {
        // --tree: print an indented dependency tree rooted at the formula.
        try printDepsTree(&idx, allocator, stdout, formula_name.?, 0, include_build);
    } else if (direct_only) {
        // --1 / --direct: print only direct dependencies.
        const deps = try idx.getStringList(allocator, entry.deps_offset);
        defer allocator.free(deps);

        for (deps) |dep| {
            try stdout.print("{s}\n", .{dep});
        }

        if (include_build) {
            const build_deps = try idx.getStringList(allocator, entry.build_deps_offset);
            defer allocator.free(build_deps);

            for (build_deps) |dep| {
                try stdout.print("{s}\n", .{dep});
            }
        }
    } else {
        // Default: full transitive closure, sorted alphabetically.
        var visited = std.StringHashMap(void).init(allocator);
        defer visited.deinit();

        var result = std.ArrayList([]const u8){};
        defer result.deinit(allocator);

        try collectTransitiveDeps(&idx, allocator, formula_name.?, &visited, &result, include_build);

        std.mem.sort([]const u8, result.items, {}, stringLessThan);

        for (result.items) |dep| {
            try stdout.print("{s}\n", .{dep});
        }
    }

    try stdout.flush();
}

/// Collect all transitive dependencies of a formula into `result`.
/// Uses `visited` to avoid cycles and duplicates.
pub fn collectTransitiveDeps(
    idx: *const Index,
    allocator: Allocator,
    name: []const u8,
    visited: *std.StringHashMap(void),
    result: *std.ArrayList([]const u8),
    include_build: bool,
) !void {
    const entry = idx.lookup(name) orelse return;
    const deps = try idx.getStringList(allocator, entry.deps_offset);
    defer allocator.free(deps);

    for (deps) |dep| {
        if (visited.contains(dep)) continue;
        try visited.put(dep, {});
        try result.append(allocator, dep);
        try collectTransitiveDeps(idx, allocator, dep, visited, result, include_build);
    }

    if (include_build) {
        const build_deps = try idx.getStringList(allocator, entry.build_deps_offset);
        defer allocator.free(build_deps);

        for (build_deps) |dep| {
            if (visited.contains(dep)) continue;
            try visited.put(dep, {});
            try result.append(allocator, dep);
            try collectTransitiveDeps(idx, allocator, dep, visited, result, include_build);
        }
    }
}

/// Print a dependency tree rooted at the given formula name.
/// Depth is capped at 32 to guard against circular dependencies.
fn printDepsTree(
    idx: *const Index,
    allocator: Allocator,
    stdout: anytype,
    name: []const u8,
    depth: usize,
    include_build: bool,
) !void {
    const max_depth = 32;
    for (0..depth) |_| try stdout.print("  ", .{});
    try stdout.print("{s}\n", .{name});

    if (depth >= max_depth) return;

    const entry = idx.lookup(name) orelse return;
    const deps = try idx.getStringList(allocator, entry.deps_offset);
    defer allocator.free(deps);
    for (deps) |dep| {
        try printDepsTree(idx, allocator, stdout, dep, depth + 1, include_build);
    }

    if (include_build) {
        const build_deps = try idx.getStringList(allocator, entry.build_deps_offset);
        defer allocator.free(build_deps);
        for (build_deps) |dep| {
            try printDepsTree(idx, allocator, stdout, dep, depth + 1, include_build);
        }
    }
}

/// Comparator for sorting string slices lexicographically.
fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "depsCmd compiles and has correct signature" {
    // Smoke test: verifies the function signature is correct and the module compiles.
    const handler: @import("../dispatch.zig").CommandFn = depsCmd;
    _ = handler;
}

test "collectTransitiveDeps builds full closure" {
    const allocator = std.testing.allocator;
    const formula_mod = @import("../formula.zig");

    const formulae = [_]formula_mod.FormulaInfo{
        .{
            .name = "a",
            .full_name = "a",
            .desc = "",
            .homepage = "",
            .license = "",
            .version = "1.0",
            .revision = 0,
            .tap = "",
            .keg_only = false,
            .deprecated = false,
            .disabled = false,
            .dependencies = &[_][]const u8{"b"},
            .build_dependencies = &.{},
            .bottle_root_url = "",
            .bottle_sha256 = "",
            .bottle_cellar = "",
        },
        .{
            .name = "b",
            .full_name = "b",
            .desc = "",
            .homepage = "",
            .license = "",
            .version = "2.0",
            .revision = 0,
            .tap = "",
            .keg_only = false,
            .deprecated = false,
            .disabled = false,
            .dependencies = &[_][]const u8{"c"},
            .build_dependencies = &.{},
            .bottle_root_url = "",
            .bottle_sha256 = "",
            .bottle_cellar = "",
        },
        .{
            .name = "c",
            .full_name = "c",
            .desc = "",
            .homepage = "",
            .license = "",
            .version = "3.0",
            .revision = 0,
            .tap = "",
            .keg_only = false,
            .deprecated = false,
            .disabled = false,
            .dependencies = &.{},
            .build_dependencies = &.{},
            .bottle_root_url = "",
            .bottle_sha256 = "",
            .bottle_cellar = "",
        },
    };

    const Index_mod = @import("../index.zig").Index;
    var idx = try Index_mod.build(allocator, &formulae);
    defer idx.deinit();

    var visited = std.StringHashMap(void).init(allocator);
    defer visited.deinit();

    var result = std.ArrayList([]const u8){};
    defer result.deinit(allocator);

    try collectTransitiveDeps(&idx, allocator, "a", &visited, &result, false);

    try std.testing.expectEqual(@as(usize, 2), result.items.len);
}
