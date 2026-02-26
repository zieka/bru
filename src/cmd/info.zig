const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const Index = @import("../index.zig").Index;
const Cellar = @import("../cellar.zig").Cellar;
const Tab = @import("../tab.zig").Tab;
const Output = @import("../output.zig").Output;

/// Show detailed information about a formula in brew-compatible format.
///
/// Usage: bru info <formula>
///
/// Loads the binary index, looks up the formula, and prints a formatted
/// summary including version, description, homepage, install status,
/// license, and dependencies.
pub fn infoCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    if (args.len == 0) {
        var err_buf: [4096]u8 = undefined;
        var ew = std.fs.File.stderr().writer(&err_buf);
        const stderr = &ew.interface;
        try stderr.print("Usage: bru info <formula>\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    const formula_name = args[0];

    var idx = try Index.loadOrBuild(allocator, config.cache);
    // Note: do not call idx.deinit() -- the index may be mmap'd (from disk)
    // in which case the allocator field is undefined. The process exits after
    // this command so OS reclamation is sufficient.

    const entry = idx.lookup(formula_name) orelse {
        const err_out = Output.initErr(config.no_color);
        err_out.err("No available formula with the name \"{s}\".", .{formula_name});
        std.process.exit(1);
    };

    const out = Output.init(config.no_color);

    // === Header: "==> name: stable version (bottled)" ===
    const name = idx.getString(entry.name_offset);
    const version = idx.getString(entry.version_offset);
    const bottle_available = (entry.flags & 8) != 0;

    // Build the section header string.
    var header_buf: [512]u8 = undefined;
    const header = if (bottle_available)
        std.fmt.bufPrint(&header_buf, "{s}: stable {s} (bottled)", .{ name, version }) catch name
    else
        std.fmt.bufPrint(&header_buf, "{s}: stable {s}", .{ name, version }) catch name;

    out.section(header);

    // === Description ===
    const desc = idx.getString(entry.desc_offset);
    if (desc.len > 0) {
        out.print("{s}\n", .{desc});
    }

    // === Homepage ===
    const homepage = idx.getString(entry.homepage_offset);
    if (homepage.len > 0) {
        out.print("{s}\n", .{homepage});
    }

    // === Install status ===
    const cellar = Cellar.init(config.cellar);
    if (cellar.installedVersions(allocator, formula_name)) |versions| {
        defer {
            for (versions) |v| allocator.free(v);
            allocator.free(versions);
        }
        out.print("Installed\n", .{});
        for (versions) |ver| {
            var keg_buf: [1024]u8 = undefined;
            const keg_path = std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ config.cellar, formula_name, ver }) catch continue;
            out.print("{s}\n", .{keg_path});
            // Try loading Tab to check if poured from bottle.
            if (Tab.loadFromKeg(allocator, keg_path)) |tab| {
                defer tab.deinit(allocator);
                if (tab.poured_from_bottle) {
                    out.print("  Poured from bottle\n", .{});
                }
            }
        }
    } else {
        out.print("Not installed\n", .{});
    }

    // === License ===
    const license = idx.getString(entry.license_offset);
    if (license.len > 0) {
        out.print("License: {s}\n", .{license});
    }

    // === Dependencies ===
    const build_deps = try idx.getStringList(allocator, entry.build_deps_offset);
    defer allocator.free(build_deps);
    const deps = try idx.getStringList(allocator, entry.deps_offset);
    defer allocator.free(deps);

    if (build_deps.len > 0 or deps.len > 0) {
        out.section("Dependencies");

        if (build_deps.len > 0) {
            out.print("Build: ", .{});
            for (build_deps, 0..) |dep, i| {
                if (i > 0) out.print(", ", .{});
                out.print("{s}", .{dep});
            }
            out.print("\n", .{});
        }

        if (deps.len > 0) {
            out.print("Required: ", .{});
            for (deps, 0..) |dep, i| {
                if (i > 0) out.print(", ", .{});
                out.print("{s}", .{dep});
            }
            out.print("\n", .{});
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "infoCmd compiles and has correct signature" {
    // Smoke test: verifies the function signature is correct and the module compiles.
    const handler: @import("../dispatch.zig").CommandFn = infoCmd;
    _ = handler;
}
