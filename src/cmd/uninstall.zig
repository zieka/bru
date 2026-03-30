const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const Cellar = @import("../cellar.zig").Cellar;
const Linker = @import("../linker.zig").Linker;
const Output = @import("../output.zig").Output;

/// Uninstall one or more formulae by unlinking from the prefix and removing kegs.
///
/// Usage: bru uninstall [--force/-f] <formula> [<formula> ...]
///
/// Removes all installed versions of each given formula from the Cellar,
/// first unlinking symlinks from the prefix, then deleting the keg
/// directories.
const ParsedUninstallArgs = struct {
    formula_names: std.ArrayList([]const u8),
};

fn parseUninstallArgs(allocator: Allocator, args: []const []const u8) ParsedUninstallArgs {
    var result = ParsedUninstallArgs{
        .formula_names = .{},
    };
    for (args) |arg| {
        if (arg.len > 0 and arg[0] == '-') continue;
        result.formula_names.append(allocator, arg) catch {};
    }
    return result;
}

pub fn uninstallCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    // 1. Parse args -- support --force/-f flag and collect all formula names.
    //    Note: --force is accepted but not acted on yet (no dependency checks).
    var parsed = parseUninstallArgs(allocator, args);
    defer parsed.formula_names.deinit(allocator);

    // 2. If no formula names, print usage and exit(1).
    if (parsed.formula_names.items.len == 0) {
        var err_buf: [4096]u8 = undefined;
        var ew = std.fs.File.stderr().writer(&err_buf);
        const stderr = &ew.interface;
        try stderr.print("Usage: bru uninstall <formula> [<formula> ...]\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    const out = Output.init(config.no_color);
    const err_out = Output.initErr(config.no_color);

    // 3. Process each formula name.
    for (parsed.formula_names.items) |raw_name| {
        // Extract simple name from tap-prefixed names (e.g. "user/tap/pkg" -> "pkg").
        const name = if (std.mem.lastIndexOfScalar(u8, raw_name, '/')) |idx|
            raw_name[idx + 1 ..]
        else
            raw_name;

        // Get installed versions — check cellar first, then caskroom.
        const cellar = Cellar.init(config.cellar);
        var base_path = config.cellar;
        var versions = cellar.installedVersions(allocator, name);
        if (versions == null) {
            const caskroom = Cellar.init(config.caskroom);
            versions = caskroom.installedVersions(allocator, name);
            if (versions != null) base_path = config.caskroom;
        }
        const installed_versions = versions orelse {
            err_out.err("{s} is not installed.", .{name});
            continue;
        };
        defer {
            for (installed_versions) |v| allocator.free(v);
            allocator.free(installed_versions);
        }

        // Set up linker.
        var linker = Linker.init(allocator, config.prefix);

        // For each version: unlink, then delete keg directory.
        for (installed_versions) |version| {
            var keg_buf: [fs.max_path_bytes]u8 = undefined;
            const keg_path = std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ base_path, name, version }) catch continue;

            out.print("Uninstalling {s} {s}...\n", .{ name, version });

            // Unlink symlinks from prefix (catch and warn on error, don't fail).
            linker.unlink(keg_path) catch |link_err| {
                out.warn("Failed to unlink {s} {s}: {s}", .{ name, version, @errorName(link_err) });
            };

            // Delete the keg directory tree.
            fs.deleteTreeAbsolute(keg_path) catch |del_err| {
                err_out.err("Could not remove {s}/{s}: {s}", .{ name, version, @errorName(del_err) });
            };
        }

        // Try to remove the formula directory if empty.
        {
            var formula_dir_buf: [fs.max_path_bytes]u8 = undefined;
            const formula_dir = std.fmt.bufPrint(&formula_dir_buf, "{s}/{s}", .{ base_path, name }) catch "";
            if (formula_dir.len > 0) {
                fs.deleteDirAbsolute(formula_dir) catch {};
            }
        }

        // Print completion section.
        const done_title = std.fmt.allocPrint(allocator, "{s} is uninstalled", .{name}) catch {
            err_out.err("Failed to format completion message for {s}.", .{name});
            continue;
        };
        defer allocator.free(done_title);
        out.section(done_title);

        // Record uninstall in state history.
        {
            var state = @import("../state.zig").State.load(allocator);
            defer state.deinit();
            state.recordAction("uninstall", name, installed_versions[0], null) catch {};
            state.save() catch {};
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "uninstallCmd compiles and has correct signature" {
    // Smoke test: verifies the function signature is correct and the module compiles.
    const handler: @import("../dispatch.zig").CommandFn = uninstallCmd;
    _ = handler;
}

test "parseUninstallArgs extracts single package name" {
    const args = &[_][]const u8{"wget"};
    var parsed = parseUninstallArgs(std.testing.allocator, args);
    defer parsed.formula_names.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), parsed.formula_names.items.len);
    try std.testing.expectEqualStrings("wget", parsed.formula_names.items[0]);
}

test "parseUninstallArgs collects multiple package names" {
    const args = &[_][]const u8{ "wget", "curl", "jq" };
    var parsed = parseUninstallArgs(std.testing.allocator, args);
    defer parsed.formula_names.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), parsed.formula_names.items.len);
    try std.testing.expectEqualStrings("wget", parsed.formula_names.items[0]);
    try std.testing.expectEqualStrings("curl", parsed.formula_names.items[1]);
    try std.testing.expectEqualStrings("jq", parsed.formula_names.items[2]);
}

test "parseUninstallArgs no arguments" {
    const args = &[_][]const u8{};
    var parsed = parseUninstallArgs(std.testing.allocator, args);
    defer parsed.formula_names.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), parsed.formula_names.items.len);
}

test "parseUninstallArgs skips flags" {
    const args = &[_][]const u8{ "--force", "git", "-f", "node" };
    var parsed = parseUninstallArgs(std.testing.allocator, args);
    defer parsed.formula_names.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), parsed.formula_names.items.len);
    try std.testing.expectEqualStrings("git", parsed.formula_names.items[0]);
    try std.testing.expectEqualStrings("node", parsed.formula_names.items[1]);
}
