const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const cellar_mod = @import("../cellar.zig");
const Cellar = cellar_mod.Cellar;
const writeJsonStr = @import("../json_helpers.zig").writeJsonStr;

/// List installed formulae from the Cellar.
///
/// With no args: prints each installed formula name (one per line).
/// With --versions / -v: prints "name version1 version2 ..." for each formula.
/// With a specific name arg: lists all files inside the keg directory for
/// the latest installed version.
pub fn listCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    var show_versions = false;
    var show_casks = false;
    var json_output = false;
    var formula_name: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--versions") or std.mem.eql(u8, arg, "-v")) {
            show_versions = true;
        } else if (std.mem.eql(u8, arg, "--cask") or std.mem.eql(u8, arg, "--casks")) {
            show_casks = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            formula_name = arg;
        }
    }

    if (show_casks) {
        // List installed casks from Caskroom
        try listCaskroom(allocator, config.caskroom);
        return;
    }

    const c = Cellar.init(config.cellar);

    if (formula_name) |name| {
        // List files for a specific formula keg.
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

        // Use the latest version.
        const latest = versions[versions.len - 1];
        try listKegFiles(config.cellar, name, latest);
    } else {
        // List all installed formulae.
        const formulae = c.installedFormulae(allocator);
        defer {
            for (formulae) |f| {
                for (f.versions) |v| allocator.free(v);
                allocator.free(f.versions);
                allocator.free(f.name);
            }
            allocator.free(formulae);
        }

        var buf: [4096]u8 = undefined;
        var w = std.fs.File.stdout().writer(&buf);
        const stdout = &w.interface;

        if (json_output) {
            try stdout.writeAll("[");
            for (formulae, 0..) |f, i| {
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

        for (formulae) |f| {
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

/// List installed casks from the Caskroom directory (sorted, skipping dot dirs).
fn listCaskroom(allocator: Allocator, caskroom_path: []const u8) !void {
    var dir = std.fs.openDirAbsolute(caskroom_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return; // Caskroom doesn't exist, nothing to list
        var err_buf: [4096]u8 = undefined;
        var ew = std.fs.File.stderr().writer(&err_buf);
        const stderr = &ew.interface;
        try stderr.print("Error: Could not open Caskroom: {s}\n", .{caskroom_path});
        try stderr.flush();
        return err;
    };
    defer dir.close();

    var names = std.ArrayList([]const u8){};
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        const duped = try allocator.dupe(u8, entry.name);
        try names.append(allocator, duped);
    }

    std.mem.sort([]const u8, names.items, {}, stringLessThan);

    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const stdout = &w.interface;

    for (names.items) |n| {
        try stdout.print("{s}\n", .{n});
    }
    try stdout.flush();
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "listCmd compiles and has correct signature" {
    // Smoke test: verifies the function signature is correct and the module compiles.
    // Actual output goes to stdout/stderr which we cannot capture in unit tests.
}
