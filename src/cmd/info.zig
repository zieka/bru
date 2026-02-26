const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const Index = @import("../index.zig").Index;
const cask_index_mod = @import("../cask_index.zig");
const CaskIndex = cask_index_mod.CaskIndex;
const CaskIndexEntry = cask_index_mod.CaskIndexEntry;
const Cellar = @import("../cellar.zig").Cellar;
const Tab = @import("../tab.zig").Tab;
const Output = @import("../output.zig").Output;
const writeJsonStr = @import("../json_helpers.zig").writeJsonStr;
const fuzzy = @import("../fuzzy.zig");

/// Show detailed information about a formula in brew-compatible format.
///
/// Usage: bru info <formula>
///
/// Loads the binary index, looks up the formula, and prints a formatted
/// summary including version, description, homepage, install status,
/// license, and dependencies.
pub fn infoCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    var json_output = false;
    var formula_name: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (formula_name == null) formula_name = arg;
        }
    }

    if (formula_name == null) {
        var err_buf: [4096]u8 = undefined;
        var ew = std.fs.File.stderr().writer(&err_buf);
        const stderr = &ew.interface;
        try stderr.print("Usage: bru info <formula>\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    var idx = try Index.loadOrBuild(allocator, config.cache);
    // Note: do not call idx.deinit() -- the index may be mmap'd (from disk)
    // in which case the allocator field is undefined. The process exits after
    // this command so OS reclamation is sufficient.

    const the_name = formula_name.?;

    const entry = idx.lookup(the_name) orelse {
        // Try cask index before erroring
        if (CaskIndex.loadOrBuild(allocator, config.cache)) |*cask_idx| {
            if (cask_idx.lookup(the_name)) |centry| {
                const out = Output.init(config.no_color);
                printCaskInfo(cask_idx, centry, out, config.caskroom, the_name);
                return;
            }
        } else |_| {}

        const err_out = Output.initErr(config.no_color);
        err_out.err("No available formula or cask with the name \"{s}\".", .{the_name});
        const similar = fuzzy.findSimilar(&idx, allocator, the_name, 3, 3) catch &.{};
        defer if (similar.len > 0) allocator.free(similar);
        if (similar.len > 0) {
            err_out.print("Did you mean?\n", .{});
            for (similar) |s| err_out.print("  {s}\n", .{s});
        }
        std.process.exit(1);
    };

    const name = idx.getString(entry.name_offset);
    const version = idx.getString(entry.version_offset);
    const bottle_available = (entry.flags & 8) != 0;
    const desc = idx.getString(entry.desc_offset);
    const homepage = idx.getString(entry.homepage_offset);
    const license = idx.getString(entry.license_offset);

    const deps = try idx.getStringList(allocator, entry.deps_offset);
    defer allocator.free(deps);
    const build_deps = try idx.getStringList(allocator, entry.build_deps_offset);
    defer allocator.free(build_deps);

    const cellar = Cellar.init(config.cellar);

    // --json: emit machine-readable JSON object
    if (json_output) {
        const installed_versions = cellar.installedVersions(allocator, the_name);
        const is_installed = installed_versions != null;
        if (installed_versions) |versions| {
            for (versions) |v| allocator.free(v);
            allocator.free(versions);
        }
        var buf: [4096]u8 = undefined;
        var w = std.fs.File.stdout().writer(&buf);
        const stdout = &w.interface;

        try stdout.writeAll("{\"name\":");
        try writeJsonStr(stdout, name);
        try stdout.writeAll(",\"full_name\":");
        try writeJsonStr(stdout, idx.getString(entry.full_name_offset));
        try stdout.writeAll(",\"version\":");
        try writeJsonStr(stdout, version);
        try stdout.print(",\"revision\":{d}", .{entry.revision});
        try stdout.writeAll(",\"desc\":");
        try writeJsonStr(stdout, desc);
        try stdout.writeAll(",\"homepage\":");
        try writeJsonStr(stdout, homepage);
        try stdout.writeAll(",\"license\":");
        try writeJsonStr(stdout, license);
        try stdout.print(",\"installed\":{s}", .{if (is_installed) "true" else "false"});
        try stdout.print(",\"bottle_available\":{s}", .{if (bottle_available) "true" else "false"});

        try stdout.writeAll(",\"dependencies\":[");
        for (deps, 0..) |dep, i| {
            if (i > 0) try stdout.writeAll(",");
            try writeJsonStr(stdout, dep);
        }
        try stdout.writeAll("]");

        try stdout.writeAll(",\"build_dependencies\":[");
        for (build_deps, 0..) |dep, i| {
            if (i > 0) try stdout.writeAll(",");
            try writeJsonStr(stdout, dep);
        }
        try stdout.writeAll("]");

        try stdout.writeAll("}\n");
        try stdout.flush();
        return;
    }

    // === Normal human-readable output ===
    const out = Output.init(config.no_color);

    // === Header: "==> name: stable version (bottled)" ===
    var header_buf: [512]u8 = undefined;
    const header = if (bottle_available)
        std.fmt.bufPrint(&header_buf, "{s}: stable {s} (bottled)", .{ name, version }) catch name
    else
        std.fmt.bufPrint(&header_buf, "{s}: stable {s}", .{ name, version }) catch name;

    out.section(header);

    if (desc.len > 0) {
        out.print("{s}\n", .{desc});
    }

    if (homepage.len > 0) {
        out.print("{s}\n", .{homepage});
    }

    // === Install status ===
    if (cellar.installedVersions(allocator, the_name)) |versions| {
        defer {
            for (versions) |v| allocator.free(v);
            allocator.free(versions);
        }
        out.print("Installed\n", .{});
        for (versions) |ver| {
            var keg_buf: [1024]u8 = undefined;
            const keg_path = std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ config.cellar, the_name, ver }) catch continue;
            out.print("{s}\n", .{keg_path});
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

    if (license.len > 0) {
        out.print("License: {s}\n", .{license});
    }

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

/// Print formatted information about a cask (similar to formula info output).
fn printCaskInfo(cask_idx: *const CaskIndex, centry: CaskIndexEntry, out: Output, caskroom_path: []const u8, token: []const u8) void {
    const name = cask_idx.getString(centry.name_offset);
    const version = cask_idx.getString(centry.version_offset);

    // === Header: "==> name: version" ===
    var header_buf: [512]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "{s}: {s} (cask)", .{ name, version }) catch name;
    out.section(header);

    // === Description ===
    const desc = cask_idx.getString(centry.desc_offset);
    if (desc.len > 0) {
        out.print("{s}\n", .{desc});
    }

    // === Homepage ===
    const homepage = cask_idx.getString(centry.homepage_offset);
    if (homepage.len > 0) {
        out.print("{s}\n", .{homepage});
    }

    // === Install status (check if directory exists in Caskroom) ===
    var cask_path_buf: [1024]u8 = undefined;
    const cask_path = std.fmt.bufPrint(&cask_path_buf, "{s}/{s}", .{ caskroom_path, token }) catch {
        out.print("Not installed\n", .{});
        return;
    };
    if (std.fs.openDirAbsolute(cask_path, .{})) |dir| {
        var d = dir;
        d.close();
        out.print("Installed\n", .{});
    } else |_| {
        out.print("Not installed\n", .{});
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
