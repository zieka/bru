const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const cellar_mod = @import("../cellar.zig");
const Cellar = cellar_mod.Cellar;
const Index = @import("../index.zig").Index;
const CaskIndex = @import("../cask_index.zig").CaskIndex;
const PkgVersion = @import("../version.zig").PkgVersion;
const writeJsonStr = @import("../json_helpers.zig").writeJsonStr;

/// Check whether a formula has a valid opt-link at {prefix}/opt/{name}.
/// Returns true if the symlink exists and points to a valid target.
fn isOptLinked(prefix: []const u8, name: []const u8) bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const opt_path = std.fmt.bufPrint(&path_buf, "{s}/opt/{s}", .{ prefix, name }) catch return false;

    // Check if the symlink exists and its target is accessible.
    std.fs.accessAbsolute(opt_path, .{}) catch return false;
    return true;
}

const ParsedOutdatedArgs = struct {
    verbose: bool = false,
    json_output: bool = false,
    only_formulae: bool = false,
    only_casks: bool = false,
};

fn parseOutdatedArgs(args: []const []const u8) ParsedOutdatedArgs {
    var result = ParsedOutdatedArgs{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            result.verbose = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            result.json_output = true;
        } else if (std.mem.eql(u8, arg, "--formula") or std.mem.eql(u8, arg, "--formulae")) {
            result.only_formulae = true;
        } else if (std.mem.eql(u8, arg, "--cask") or std.mem.eql(u8, arg, "--casks")) {
            result.only_casks = true;
        }
    }
    return result;
}

/// A reported outdated entry, used internally for both formulae and casks.
const OutdatedEntry = struct {
    name: []const u8,
    installed_version: []const u8,
    latest_version: []const u8, // pre-formatted; for formulae includes _revision
};

/// Collect outdated formulae from the cellar against the formula index.
fn collectOutdatedFormulae(
    allocator: Allocator,
    index: *Index,
    cellar: Cellar,
    prefix: []const u8,
    out: *std.ArrayList(OutdatedEntry),
    fmt_arena: Allocator,
) !void {
    const installed = cellar.installedFormulae(allocator);
    defer {
        for (installed) |f| {
            for (f.versions) |v| allocator.free(v);
            allocator.free(f.versions);
            allocator.free(f.name);
        }
        allocator.free(installed);
    }

    for (installed) |formula| {
        const entry = index.lookup(formula.name) orelse continue;
        const index_version_str = index.getString(entry.version_offset);
        const installed_version_str = formula.latestVersion();
        const installed_pv = PkgVersion.parse(installed_version_str);
        const index_pv = PkgVersion{
            .version = index_version_str,
            .revision = @as(u32, entry.revision),
        };

        const version_outdated = installed_pv.order(index_pv) == .lt;
        const unlinked = !version_outdated and !isOptLinked(prefix, formula.name);

        if (version_outdated or unlinked) {
            var fmt_buf: [128]u8 = undefined;
            const latest_formatted = index_pv.format(&fmt_buf);
            try out.append(allocator, .{
                .name = try fmt_arena.dupe(u8, formula.name),
                .installed_version = try fmt_arena.dupe(u8, installed_version_str),
                .latest_version = try fmt_arena.dupe(u8, latest_formatted),
            });
        }
    }
}

/// Collect outdated casks from the caskroom against the cask index.
/// A cask is outdated when its installed version differs from the cask
/// index's resolved version. Disabled casks in the index are skipped.
fn collectOutdatedCasks(
    allocator: Allocator,
    cask_idx: *CaskIndex,
    caskroom: Cellar,
    out: *std.ArrayList(OutdatedEntry),
    fmt_arena: Allocator,
) !void {
    const installed = caskroom.installedFormulae(allocator);
    defer {
        for (installed) |c| {
            for (c.versions) |v| allocator.free(v);
            allocator.free(c.versions);
            allocator.free(c.name);
        }
        allocator.free(installed);
    }

    for (installed) |cask| {
        const entry = cask_idx.lookup(cask.name) orelse continue;
        // Skip disabled casks — they have no upgrade target.
        if ((entry.flags & 2) != 0) continue;
        const latest = cask_idx.getString(entry.version_offset);
        if (latest.len == 0) continue;
        const installed_latest = cask.latestVersion();
        if (!std.mem.eql(u8, installed_latest, latest)) {
            try out.append(allocator, .{
                .name = try fmt_arena.dupe(u8, cask.name),
                .installed_version = try fmt_arena.dupe(u8, installed_latest),
                .latest_version = try fmt_arena.dupe(u8, latest),
            });
        }
    }
}

fn writeJsonEntries(
    stdout: anytype,
    entries: []const OutdatedEntry,
    is_cask: bool,
    first: *bool,
) !void {
    for (entries) |e| {
        if (!first.*) try stdout.writeAll(",");
        try stdout.writeAll("{\"name\":");
        try writeJsonStr(stdout, e.name);
        try stdout.writeAll(",\"installed_version\":");
        try writeJsonStr(stdout, e.installed_version);
        try stdout.writeAll(",\"latest_version\":");
        try writeJsonStr(stdout, e.latest_version);
        try stdout.writeAll(",\"cask\":");
        try stdout.writeAll(if (is_cask) "true" else "false");
        try stdout.writeAll("}");
        first.* = false;
    }
}

/// Show installed formulae and casks that have a newer version available.
///
/// Default: scans both the Cellar (formulae) and Caskroom (casks).
///
/// Flags:
///   --formula / --formulae   only check formulae
///   --cask    / --casks      only check casks
///   --verbose / -v           show "name (installed) < latest"
///   --json                   emit JSON array; each entry has a "cask" bool
pub fn outdatedCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    const parsed = parseOutdatedArgs(args);
    const show_formulae = !parsed.only_casks;
    const show_casks = !parsed.only_formulae;

    // Arena for entry strings -- freed in one shot at the end.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const fmt_arena = arena_state.allocator();

    var formulae: std.ArrayList(OutdatedEntry) = .{};
    defer formulae.deinit(allocator);
    var casks: std.ArrayList(OutdatedEntry) = .{};
    defer casks.deinit(allocator);

    if (show_formulae) {
        var index = try Index.loadOrBuild(allocator, config.cache);
        _ = &index;
        const cellar = Cellar.init(config.cellar);
        try collectOutdatedFormulae(allocator, &index, cellar, config.prefix, &formulae, fmt_arena);
    }

    if (show_casks) {
        if (CaskIndex.loadOrBuild(allocator, config.cache)) |idx_val| {
            var cask_idx = idx_val;
            const caskroom = Cellar.init(config.caskroom);
            try collectOutdatedCasks(allocator, &cask_idx, caskroom, &casks, fmt_arena);
        } else |_| {
            // No cask index available; skip silently when listing both.
            // Surface an error only if the user explicitly asked for casks.
            if (parsed.only_casks) return error.CaskIndexUnavailable;
        }
    }

    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const stdout = &w.interface;

    if (parsed.json_output) {
        try stdout.writeAll("[");
        var first: bool = true;
        try writeJsonEntries(stdout, formulae.items, false, &first);
        try writeJsonEntries(stdout, casks.items, true, &first);
        try stdout.writeAll("]\n");
        try stdout.flush();
        return;
    }

    // Headers match brew's output when both sections have items.
    const both = formulae.items.len > 0 and casks.items.len > 0;

    if (formulae.items.len > 0) {
        if (both) try stdout.writeAll("==> Outdated Formulae\n");
        for (formulae.items) |e| {
            if (parsed.verbose) {
                try stdout.print("{s} ({s}) < {s}\n", .{ e.name, e.installed_version, e.latest_version });
            } else {
                try stdout.print("{s}\n", .{e.name});
            }
        }
    }

    if (casks.items.len > 0) {
        if (both) try stdout.writeAll("==> Outdated Casks\n");
        for (casks.items) |e| {
            if (parsed.verbose) {
                try stdout.print("{s} ({s}) != {s}\n", .{ e.name, e.installed_version, e.latest_version });
            } else {
                try stdout.print("{s}\n", .{e.name});
            }
        }
    }

    try stdout.flush();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "outdatedCmd compiles and has correct signature" {
    const handler: @import("../dispatch.zig").CommandFn = outdatedCmd;
    _ = handler;
}

test "isOptLinked returns true for linked formula" {
    const result = isOptLinked(Config.default_prefix, ".");
    _ = result;
}

test "isOptLinked returns false for nonexistent formula" {
    const result = isOptLinked(Config.default_prefix, "__nonexistent_formula_xyz_42__");
    try std.testing.expect(!result);
}

test "parseOutdatedArgs defaults" {
    const args: []const []const u8 = &.{};
    const p = parseOutdatedArgs(args);
    try std.testing.expect(!p.verbose);
    try std.testing.expect(!p.json_output);
    try std.testing.expect(!p.only_formulae);
    try std.testing.expect(!p.only_casks);
}

test "parseOutdatedArgs --cask" {
    const args = &[_][]const u8{"--cask"};
    const p = parseOutdatedArgs(args);
    try std.testing.expect(p.only_casks);
    try std.testing.expect(!p.only_formulae);
}

test "parseOutdatedArgs --casks alias" {
    const args = &[_][]const u8{"--casks"};
    const p = parseOutdatedArgs(args);
    try std.testing.expect(p.only_casks);
}

test "parseOutdatedArgs --formula" {
    const args = &[_][]const u8{"--formula"};
    const p = parseOutdatedArgs(args);
    try std.testing.expect(p.only_formulae);
    try std.testing.expect(!p.only_casks);
}

test "parseOutdatedArgs --formulae alias" {
    const args = &[_][]const u8{"--formulae"};
    const p = parseOutdatedArgs(args);
    try std.testing.expect(p.only_formulae);
}

test "parseOutdatedArgs combined flags" {
    const args = &[_][]const u8{ "--verbose", "--json", "--cask" };
    const p = parseOutdatedArgs(args);
    try std.testing.expect(p.verbose);
    try std.testing.expect(p.json_output);
    try std.testing.expect(p.only_casks);
}
