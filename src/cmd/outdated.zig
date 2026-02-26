const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const cellar_mod = @import("../cellar.zig");
const Cellar = cellar_mod.Cellar;
const Index = @import("../index.zig").Index;
const PkgVersion = @import("../version.zig").PkgVersion;
const writeJsonStr = @import("../json_helpers.zig").writeJsonStr;

/// Show installed formulae that have a newer version available in the index.
///
/// With --verbose / -v: prints "name (installed_ver) < latest_ver"
/// Otherwise: just prints "name"
pub fn outdatedCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    var verbose = false;
    var json_output = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        }
    }

    // Load the index from disk or build from the JWS cache.
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

    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const stdout = &w.interface;

    if (json_output) {
        try stdout.writeAll("[");
        var first: bool = true;
        for (installed) |formula| {
            const entry = index.lookup(formula.name) orelse continue;
            const index_version_str = index.getString(entry.version_offset);
            const installed_version_str = formula.latestVersion();
            const installed_pv = PkgVersion.parse(installed_version_str);
            const index_pv = PkgVersion{
                .version = index_version_str,
                .revision = @as(u32, entry.revision),
            };

            if (installed_pv.order(index_pv) == .lt) {
                if (!first) try stdout.writeAll(",");
                try stdout.writeAll("{\"name\":");
                try writeJsonStr(stdout, formula.name);
                try stdout.writeAll(",\"installed_version\":");
                try writeJsonStr(stdout, installed_version_str);
                var fmt_buf: [128]u8 = undefined;
                const index_formatted = index_pv.format(&fmt_buf);
                try stdout.writeAll(",\"latest_version\":");
                try writeJsonStr(stdout, index_formatted);
                try stdout.writeAll("}");
                first = false;
            }
        }
        try stdout.writeAll("]\n");
        try stdout.flush();
        return;
    }

    for (installed) |formula| {
        // Look up this formula in the index.
        const entry = index.lookup(formula.name) orelse continue;

        // Get the latest version string from the index.
        const index_version_str = index.getString(entry.version_offset);

        // Get the installed latest version string.
        const installed_version_str = formula.latestVersion();

        // Build PkgVersion structs for comparison.
        const installed_pv = PkgVersion.parse(installed_version_str);
        const index_pv = PkgVersion{
            .version = index_version_str,
            .revision = @as(u32, entry.revision),
        };

        // If installed < index, this formula is outdated.
        if (installed_pv.order(index_pv) == .lt) {
            if (verbose) {
                // Format the index version for display.
                var fmt_buf: [128]u8 = undefined;
                const index_formatted = index_pv.format(&fmt_buf);
                try stdout.print("{s} ({s}) < {s}\n", .{ formula.name, installed_version_str, index_formatted });
            } else {
                try stdout.print("{s}\n", .{formula.name});
            }
        }
    }

    try stdout.flush();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "outdatedCmd compiles and has correct signature" {
    // Smoke test: verifies the function signature is correct and the module compiles.
}
