const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const Cellar = @import("../cellar.zig").Cellar;
const Linker = @import("../linker.zig").Linker;
const Output = @import("../output.zig").Output;

/// Link a formula's keg into the Homebrew prefix.
///
/// Usage: bru link <formula>
///
/// Creates symlinks from the keg (latest installed version) into the
/// prefix directories (bin, lib, include, etc.) and sets up the opt link.
pub fn linkCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    // 1. Get formula name from first non-flag argument.
    var formula_name: ?[]const u8 = null;
    for (args) |arg| {
        if (arg.len > 0 and arg[0] == '-') continue;
        if (formula_name == null) {
            formula_name = arg;
        }
    }

    const name = formula_name orelse {
        var err_buf: [4096]u8 = undefined;
        var ew = std.fs.File.stderr().writer(&err_buf);
        const stderr = &ew.interface;
        try stderr.print("Usage: bru link <formula>\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    const out = Output.init(config.no_color);
    const err_out = Output.initErr(config.no_color);

    // 2. Get installed versions via cellar.
    const cellar = Cellar.init(config.cellar);
    const versions = cellar.installedVersions(allocator, name) orelse {
        err_out.err("{s} is not installed.", .{name});
        std.process.exit(1);
    };
    defer {
        for (versions) |v| allocator.free(v);
        allocator.free(versions);
    }

    // 3. Get latest version (last in sorted array).
    const latest = versions[versions.len - 1];

    // 4. Construct keg path: {cellar}/{name}/{latest}
    var keg_buf: [fs.max_path_bytes]u8 = undefined;
    const keg_path = std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ config.cellar, name, latest }) catch {
        err_out.err("Path too long for {s}/{s}", .{ name, latest });
        std.process.exit(1);
    };

    // 5. Link keg into prefix.
    out.print("Linking {s} {s}...\n", .{ name, latest });

    var linker = Linker.init(allocator, config.prefix);
    try linker.link(name, keg_path);
}

/// Unlink a formula's keg from the Homebrew prefix.
///
/// Usage: bru unlink <formula>
///
/// Removes symlinks from the prefix that point into the formula's keg
/// (latest installed version).
pub fn unlinkCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    // 1. Get formula name from first non-flag argument.
    var formula_name: ?[]const u8 = null;
    for (args) |arg| {
        if (arg.len > 0 and arg[0] == '-') continue;
        if (formula_name == null) {
            formula_name = arg;
        }
    }

    const name = formula_name orelse {
        var err_buf: [4096]u8 = undefined;
        var ew = std.fs.File.stderr().writer(&err_buf);
        const stderr = &ew.interface;
        try stderr.print("Usage: bru unlink <formula>\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    const out = Output.init(config.no_color);
    const err_out = Output.initErr(config.no_color);

    // 2. Get installed versions via cellar.
    const cellar = Cellar.init(config.cellar);
    const versions = cellar.installedVersions(allocator, name) orelse {
        err_out.err("{s} is not installed.", .{name});
        std.process.exit(1);
    };
    defer {
        for (versions) |v| allocator.free(v);
        allocator.free(versions);
    }

    // 3. Get latest version (last in sorted array).
    const latest = versions[versions.len - 1];

    // 4. Construct keg path: {cellar}/{name}/{latest}
    var keg_buf: [fs.max_path_bytes]u8 = undefined;
    const keg_path = std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ config.cellar, name, latest }) catch {
        err_out.err("Path too long for {s}/{s}", .{ name, latest });
        std.process.exit(1);
    };

    // 5. Unlink keg from prefix.
    out.print("Unlinking {s} {s}...\n", .{ name, latest });

    var linker = Linker.init(allocator, config.prefix);
    try linker.unlink(keg_path);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "linkCmd compiles and has correct signature" {
    // Smoke test: verifies the function signature is correct and the module compiles.
    const handler: @import("../dispatch.zig").CommandFn = linkCmd;
    _ = handler;
}

test "unlinkCmd compiles and has correct signature" {
    // Smoke test: verifies the function signature is correct and the module compiles.
    const handler: @import("../dispatch.zig").CommandFn = unlinkCmd;
    _ = handler;
}
