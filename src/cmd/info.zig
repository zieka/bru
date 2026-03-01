const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const Index = @import("../index.zig").Index;
const IndexEntry = @import("../index.zig").IndexEntry;
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
        err_out.print("Searched: {s}/api/formula.jws.json\n", .{config.cache});
        const similar = fuzzy.findSimilar(&idx, allocator, the_name, 3, 3) catch &.{};
        defer if (similar.len > 0) allocator.free(similar);
        if (similar.len > 0) {
            err_out.print("Did you mean?\n", .{});
            for (similar) |s| err_out.print("  {s}\n", .{s});
        }
        std.process.exit(1);
    };

    const cellar = Cellar.init(config.cellar);

    // --json: emit machine-readable JSON object
    if (json_output) {
        try printJson(allocator, &idx, entry, the_name, cellar);
        return;
    }

    // === Normal human-readable output ===
    try printHuman(allocator, &idx, entry, the_name, cellar, config);
}

/// Construct the GitHub source URL from a tap string and formula name.
/// e.g. "homebrew/core" + "git" → "https://github.com/Homebrew/homebrew-core/blob/HEAD/Formula/g/git.rb"
fn buildFromUrl(buf: []u8, tap: []const u8, name: []const u8) ?[]const u8 {
    // Tap format: "org/repo" (e.g. "homebrew/core")
    const slash = std.mem.indexOfScalar(u8, tap, '/') orelse return null;
    if (slash == 0 or slash + 1 >= tap.len) return null;
    const org_raw = tap[0..slash];
    const repo_raw = tap[slash + 1 ..];
    if (name.len == 0) return null;

    // Capitalize first letter of org: "homebrew" → "Homebrew"
    var org_buf: [128]u8 = undefined;
    if (org_raw.len > org_buf.len) return null;
    @memcpy(org_buf[0..org_raw.len], org_raw);
    if (org_buf[0] >= 'a' and org_buf[0] <= 'z') {
        org_buf[0] -= 32;
    }
    const org = org_buf[0..org_raw.len];

    return std.fmt.bufPrint(buf, "https://github.com/{s}/homebrew-{s}/blob/HEAD/Formula/{c}/{s}.rb", .{ org, repo_raw, name[0], name }) catch null;
}

/// Print human-readable info output matching brew's format.
fn printHuman(allocator: Allocator, idx: *const Index, entry: IndexEntry, the_name: []const u8, cellar: Cellar, config: Config) !void {
    const name = idx.getString(entry.name_offset);
    const version = idx.getString(entry.version_offset);
    const bottle_available = (entry.flags & 8) != 0;
    const has_head = (entry.flags & 16) != 0;
    const desc = idx.getString(entry.desc_offset);
    const homepage = idx.getString(entry.homepage_offset);
    const license = idx.getString(entry.license_offset);
    const tap = idx.getString(entry.tap_offset);
    const caveats = idx.getString(entry.caveats_offset);

    const deps = try idx.getStringList(allocator, entry.deps_offset);
    defer allocator.free(deps);
    const build_deps = try idx.getStringList(allocator, entry.build_deps_offset);
    defer allocator.free(build_deps);

    const out = Output.init(config.no_color);

    // Check install status early (needed for header indicator)
    const installed_versions = cellar.installedVersions(allocator, the_name);
    const is_installed = installed_versions != null;

    // === Header: "==> name ✓: stable version (bottled), HEAD" ===
    var header_buf: [512]u8 = undefined;
    const indicator = if (config.no_emoji) "" else if (is_installed) " \xe2\x9c\x93" else " \xe2\x9c\x97";
    const head_suffix = if (has_head) ", HEAD" else "";
    const header = if (bottle_available)
        std.fmt.bufPrint(&header_buf, "{s}{s}: stable {s} (bottled){s}", .{ name, indicator, version, head_suffix }) catch name
    else
        std.fmt.bufPrint(&header_buf, "{s}{s}: stable {s}{s}", .{ name, indicator, version, head_suffix }) catch name;

    out.section(header);

    if (desc.len > 0) {
        out.print("{s}\n", .{desc});
    }

    if (homepage.len > 0) {
        out.print("{s}\n", .{homepage});
    }

    // === Install status ===
    if (installed_versions) |versions| {
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

    // === From: line ===
    var from_buf: [512]u8 = undefined;
    if (buildFromUrl(&from_buf, tap, name)) |url| {
        out.print("From: {s}\n", .{url});
    }

    if (license.len > 0) {
        out.print("License: {s}\n", .{license});
    }

    // === Dependencies ===
    if (build_deps.len > 0 or deps.len > 0) {
        out.section("Dependencies");

        if (build_deps.len > 0) {
            out.print("Build: ", .{});
            for (build_deps, 0..) |dep, i| {
                if (i > 0) out.print(", ", .{});
                out.print("{s}", .{dep});
                if (!config.no_emoji) {
                    if (cellar.isInstalled(dep)) {
                        out.print(" \xe2\x9c\x93", .{});
                    } else {
                        out.print(" \xe2\x9c\x97", .{});
                    }
                }
            }
            out.print("\n", .{});
        }

        if (deps.len > 0) {
            out.print("Required: ", .{});
            for (deps, 0..) |dep, i| {
                if (i > 0) out.print(", ", .{});
                out.print("{s}", .{dep});
                if (!config.no_emoji) {
                    if (cellar.isInstalled(dep)) {
                        out.print(" \xe2\x9c\x93", .{});
                    } else {
                        out.print(" \xe2\x9c\x97", .{});
                    }
                }
            }
            out.print("\n", .{});
        }
    }

    // === Options ===
    if (has_head) {
        out.section("Options");
        out.print("--HEAD\n\tInstall HEAD version\n", .{});
    }

    // === Caveats ===
    if (caveats.len > 0) {
        out.section("Caveats");
        out.print("{s}\n", .{caveats});
    }
}

/// Print JSON info output.
fn printJson(allocator: Allocator, idx: *const Index, entry: IndexEntry, the_name: []const u8, cellar: Cellar) !void {
    const name = idx.getString(entry.name_offset);
    const version = idx.getString(entry.version_offset);
    const bottle_available = (entry.flags & 8) != 0;
    const has_head = (entry.flags & 16) != 0;
    const desc = idx.getString(entry.desc_offset);
    const homepage = idx.getString(entry.homepage_offset);
    const license = idx.getString(entry.license_offset);
    const caveats = idx.getString(entry.caveats_offset);

    const deps = try idx.getStringList(allocator, entry.deps_offset);
    defer allocator.free(deps);
    const build_deps = try idx.getStringList(allocator, entry.build_deps_offset);
    defer allocator.free(build_deps);

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
    try stdout.print(",\"has_head\":{s}", .{if (has_head) "true" else "false"});
    try stdout.writeAll(",\"caveats\":");
    try writeJsonStr(stdout, caveats);

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
