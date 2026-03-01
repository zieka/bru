const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const Index = @import("../index.zig").Index;
const Cellar = @import("../cellar.zig").Cellar;
const Output = @import("../output.zig").Output;
const fuzzy = @import("../fuzzy.zig");

/// Find all formulae in the index that depend on `target_name`.
/// If `include_build` is true, also check build dependencies.
pub fn findUses(
    idx: *const Index,
    allocator: Allocator,
    target_name: []const u8,
    result: *std.ArrayList([]const u8),
    include_build: bool,
) !void {
    const count = idx.entryCount();
    for (0..count) |i| {
        const entry = idx.getEntryByIndex(@intCast(i));
        const name = idx.getString(entry.name_offset);

        // Check runtime deps
        const deps = try idx.getStringList(allocator, entry.deps_offset);
        defer allocator.free(deps);

        var found = false;
        for (deps) |dep| {
            if (std.mem.eql(u8, dep, target_name)) {
                found = true;
                break;
            }
        }

        if (!found and include_build) {
            const build_deps = try idx.getStringList(allocator, entry.build_deps_offset);
            defer allocator.free(build_deps);
            for (build_deps) |dep| {
                if (std.mem.eql(u8, dep, target_name)) {
                    found = true;
                    break;
                }
            }
        }

        if (found) {
            try result.append(allocator, name);
        }
    }
}

/// Show which formulae depend on the given formula.
///
/// Usage: bru uses [--installed] [--include-build] <formula>
pub fn usesCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    var installed_only = false;
    var include_build = false;
    var formula_name: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--installed")) {
            installed_only = true;
        } else if (std.mem.eql(u8, arg, "--include-build")) {
            include_build = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (formula_name == null) formula_name = arg;
        }
    }

    if (formula_name == null) {
        var err_buf: [4096]u8 = undefined;
        var ew = std.fs.File.stderr().writer(&err_buf);
        const stderr = &ew.interface;
        try stderr.print("Usage: bru uses [--installed] [--include-build] <formula>\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    var idx = try Index.loadOrBuild(allocator, config.cache);

    // Verify the target formula exists
    _ = idx.lookup(formula_name.?) orelse {
        const err_out = Output.initErr(config.no_color);
        err_out.err("No available formula with the name \"{s}\".", .{formula_name.?});
        err_out.print("Searched: {s}/api/formula.jws.json\n", .{config.cache});
        const similar = fuzzy.findSimilar(&idx, allocator, formula_name.?, 3, 3) catch &.{};
        defer if (similar.len > 0) allocator.free(similar);
        if (similar.len > 0) {
            err_out.print("Did you mean?\n", .{});
            for (similar) |s| err_out.print("  {s}\n", .{s});
        }
        std.process.exit(1);
    };

    var result = std.ArrayList([]const u8){};
    defer result.deinit(allocator);

    try findUses(&idx, allocator, formula_name.?, &result, include_build);

    // Optionally filter to installed only
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const stdout = &w.interface;

    if (installed_only) {
        const cellar = Cellar.init(config.cellar);
        for (result.items) |name| {
            if (cellar.isInstalled(name)) {
                try stdout.print("{s}\n", .{name});
            }
        }
    } else {
        for (result.items) |name| {
            try stdout.print("{s}\n", .{name});
        }
    }

    try stdout.flush();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "usesCmd compiles and has correct signature" {
    const handler: @import("../dispatch.zig").CommandFn = usesCmd;
    _ = handler;
}

test "findUses returns formulae that depend on target" {
    const allocator = std.testing.allocator;
    const formula_mod = @import("../formula.zig");

    const formulae = [_]formula_mod.FormulaInfo{
        .{
            .name = "bat",
            .full_name = "bat",
            .desc = "",
            .homepage = "",
            .license = "",
            .version = "0.26.1",
            .revision = 0,
            .tap = "",
            .keg_only = false,
            .deprecated = false,
            .disabled = false,
            .has_head = false,
            .caveats = "",
            .dependencies = &[_][]const u8{ "libgit2", "oniguruma" },
            .build_dependencies = &.{},
            .bottle_root_url = "",
            .bottle_sha256 = "",
            .bottle_cellar = "",
        },
        .{
            .name = "git",
            .full_name = "git",
            .desc = "",
            .homepage = "",
            .license = "",
            .version = "2.47.0",
            .revision = 0,
            .tap = "",
            .keg_only = false,
            .deprecated = false,
            .disabled = false,
            .has_head = false,
            .caveats = "",
            .dependencies = &[_][]const u8{"pcre2"},
            .build_dependencies = &.{},
            .bottle_root_url = "",
            .bottle_sha256 = "",
            .bottle_cellar = "",
        },
        .{
            .name = "libgit2",
            .full_name = "libgit2",
            .desc = "",
            .homepage = "",
            .license = "",
            .version = "1.9.0",
            .revision = 0,
            .tap = "",
            .keg_only = false,
            .deprecated = false,
            .disabled = false,
            .has_head = false,
            .caveats = "",
            .dependencies = &.{},
            .build_dependencies = &.{},
            .bottle_root_url = "",
            .bottle_sha256 = "",
            .bottle_cellar = "",
        },
    };

    var idx = try Index.build(allocator, &formulae);
    defer idx.deinit();

    // "libgit2" is used by "bat"
    var result = std.ArrayList([]const u8){};
    defer result.deinit(allocator);

    try findUses(&idx, allocator, "libgit2", &result, false);

    try std.testing.expectEqual(@as(usize, 1), result.items.len);
    try std.testing.expectEqualStrings("bat", result.items[0]);
}
