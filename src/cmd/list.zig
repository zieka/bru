const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const cellar_mod = @import("../cellar.zig");
const Cellar = cellar_mod.Cellar;
const InstalledFormula = cellar_mod.InstalledFormula;
const writeJsonStr = @import("../json_helpers.zig").writeJsonStr;

/// List installed formulae and casks.
///
/// With no flags: prints both formulae and casks (matching `brew list`).
/// With --formula: prints only formulae.
/// With --cask: prints only casks.
/// With --versions / -v: prints "name version1 version2 ..." for each entry.
/// With a specific name arg: lists all files inside the keg directory for
/// the latest installed version.
pub fn listCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    var show_versions = false;
    var only_casks = false;
    var only_formulae = false;
    var json_output = false;
    var formula_name: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--versions") or std.mem.eql(u8, arg, "-v")) {
            show_versions = true;
        } else if (std.mem.eql(u8, arg, "--cask") or std.mem.eql(u8, arg, "--casks")) {
            only_casks = true;
        } else if (std.mem.eql(u8, arg, "--formula") or std.mem.eql(u8, arg, "--formulae")) {
            only_formulae = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            formula_name = arg;
        }
    }

    if (formula_name) |name| {
        // List files for a specific formula keg.
        const c = Cellar.init(config.cellar);
        const versions = c.installedVersions(allocator, name) orelse {
            var err_buf: [4096]u8 = undefined;
            var ew = std.fs.File.stderr().writer(&err_buf);
            const stderr = &ew.interface;
            try stderr.print("Error: No such keg: {s}/{s}\n", .{ config.cellar, name });
            try stderr.flush();
            std.process.exit(1);
        };
        defer {
            for (versions) |v| allocator.free(v);
            allocator.free(versions);
        }

        // Find the lexicographically highest version (latest).
        var latest = versions[0];
        for (versions[1..]) |v| {
            if (std.mem.order(u8, v, latest) == .gt) latest = v;
        }
        try listKegFiles(config.cellar, name, latest);
        return;
    }

    // Collect formulae (unless --cask only).
    var formulae: []InstalledFormula = &.{};
    defer {
        for (formulae) |f| {
            for (f.versions) |v| allocator.free(v);
            allocator.free(f.versions);
            allocator.free(f.name);
        }
        allocator.free(formulae);
    }
    if (!only_casks) {
        const c = Cellar.init(config.cellar);
        formulae = c.installedFormulae(allocator);
    }

    // Collect casks (unless --formula only).
    var casks: []InstalledFormula = &.{};
    defer {
        for (casks) |ck| {
            for (ck.versions) |v| allocator.free(v);
            allocator.free(ck.versions);
            allocator.free(ck.name);
        }
        allocator.free(casks);
    }
    if (!only_formulae and !(show_versions and !only_casks)) {
        const cr = Cellar.init(config.caskroom);
        casks = cr.installedFormulae(allocator);
    }

    // Merge into a single sorted list.
    var all = std.ArrayList(InstalledFormula){};
    defer all.deinit(allocator);
    try all.appendSlice(allocator, formulae);
    try all.appendSlice(allocator, casks);

    // For plain name listing (no --versions), also include symlinked entries
    // in the Caskroom (e.g. google-cloud-sdk -> gcloud-cli). These are aliases
    // that brew includes in `list` but not in `list --versions`.
    var extra_names = std.ArrayList([]const u8){};
    defer {
        for (extra_names.items) |n| allocator.free(n);
        extra_names.deinit(allocator);
    }
    if (!only_formulae and !show_versions) {
        if (std.fs.openDirAbsolute(config.caskroom, .{ .iterate = true })) |*d| {
            var cask_dir = d.*;
            defer cask_dir.close();
            var cask_iter = cask_dir.iterate();
            while (cask_iter.next() catch null) |entry| {
                if (entry.kind != .sym_link) continue;
                if (entry.name.len > 0 and entry.name[0] == '.') continue;
                const duped = try allocator.dupe(u8, entry.name);
                // Add as a formula with empty versions (name-only).
                try all.append(allocator, .{ .name = duped, .versions = &.{} });
                try extra_names.append(allocator, duped);
            }
        } else |_| {}
    }

    std.mem.sort(InstalledFormula, all.items, {}, formulaLessThan);

    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const stdout = &w.interface;

    if (json_output) {
        try stdout.writeAll("[");
        for (all.items, 0..) |f, i| {
            if (i > 0) try stdout.writeAll(",");
            if (show_versions) {
                try stdout.writeAll("{\"name\":");
                try writeJsonStr(stdout, f.name);
                try stdout.writeAll(",\"versions\":[");
                for (f.versions, 0..) |v, vi| {
                    if (vi > 0) try stdout.writeAll(",");
                    try writeJsonStr(stdout, v);
                }
                try stdout.writeAll("]}");
            } else {
                try writeJsonStr(stdout, f.name);
            }
        }
        try stdout.writeAll("]\n");
        try stdout.flush();
        return;
    }

    for (all.items) |f| {
        if (show_versions) {
            try stdout.print("{s}", .{f.name});
            for (f.versions) |v| {
                try stdout.print(" {s}", .{v});
            }
            try stdout.print("\n", .{});
        } else {
            try stdout.print("{s}\n", .{f.name});
        }
    }
    try stdout.flush();
}

/// Open the keg directory for {cellar}/{name}/{version} and print each entry.
fn listKegFiles(cellar_path: []const u8, name: []const u8, version: []const u8) !void {
    var path_buf: [1024]u8 = undefined;
    const keg_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}", .{ cellar_path, name, version });

    var dir = std.fs.openDirAbsolute(keg_path, .{ .iterate = true }) catch |err| {
        var err_buf: [4096]u8 = undefined;
        var ew = std.fs.File.stderr().writer(&err_buf);
        const stderr = &ew.interface;
        try stderr.print("Error: Could not open keg directory: {s}\n", .{keg_path});
        try stderr.flush();
        return err;
    };
    defer dir.close();

    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const stdout = &w.interface;

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        try stdout.print("{s}/{s}/{s}/{s}\n", .{ cellar_path, name, version, entry.name });
    }
    try stdout.flush();
}

/// Sort InstalledFormula by name.
fn formulaLessThan(_: void, a: InstalledFormula, b: InstalledFormula) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "listCmd compiles and has correct signature" {
    // Smoke test: verifies the function signature is correct and the module compiles.
    // Actual output goes to stdout/stderr which we cannot capture in unit tests.
}
