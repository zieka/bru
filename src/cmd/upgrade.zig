const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const cellar_mod = @import("../cellar.zig");
const Cellar = cellar_mod.Cellar;
const Index = @import("../index.zig").Index;
const PkgVersion = @import("../version.zig").PkgVersion;
const Output = @import("../output.zig").Output;
const fallback = @import("../fallback.zig");

/// An outdated formula pending upgrade.
const OutdatedFormula = struct {
    name: []const u8,
    installed_version: []const u8,
    index_version: PkgVersion,
};

/// Upgrade outdated formulae by detecting version differences and delegating
/// to `brew upgrade` for the actual upgrade process.
///
/// Usage:
///   bru upgrade              — upgrade all outdated formulae
///   bru upgrade <formula>    — upgrade a specific formula
pub fn upgradeCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    const out = Output.init(config.no_color);
    const err_out = Output.initErr(config.no_color);

    // Parse args — find the first non-flag argument as formula name.
    var formula_name: ?[]const u8 = null;
    for (args) |arg| {
        if (arg.len > 0 and arg[0] == '-') continue;
        formula_name = arg;
        break;
    }

    // Load index.
    var index = try Index.loadOrBuild(allocator, config.cache);
    // Note: do not call index.deinit() -- the index may be mmap'd (from disk)
    // in which case the allocator field is undefined. The process exits after
    // this command so OS reclamation is sufficient.
    _ = &index;

    // Load cellar.
    const cellar = Cellar.init(config.cellar);

    // Collect outdated formulae to upgrade.
    var to_upgrade: std.ArrayList(OutdatedFormula) = .{};
    defer to_upgrade.deinit(allocator);

    if (formula_name) |name| {
        // Specific formula requested — check if installed and outdated.
        if (!cellar.isInstalled(name)) {
            err_out.err("{s} is not installed.", .{name});
            std.process.exit(1);
        }

        const entry = index.lookup(name) orelse {
            err_out.err("No available formula with the name \"{s}\".", .{name});
            std.process.exit(1);
        };

        const installed_versions = cellar.installedVersions(allocator, name) orelse {
            err_out.err("{s} is not installed.", .{name});
            std.process.exit(1);
        };
        defer {
            for (installed_versions) |v| allocator.free(v);
            allocator.free(installed_versions);
        }

        // Use the latest installed version.
        const installed_latest = installed_versions[installed_versions.len - 1];
        const installed_pv = PkgVersion.parse(installed_latest);
        const index_pv = PkgVersion{
            .version = index.getString(entry.version_offset),
            .revision = @as(u32, entry.revision),
        };

        if (installed_pv.order(index_pv) == .lt) {
            try to_upgrade.append(allocator, .{
                .name = name,
                .installed_version = try allocator.dupe(u8, installed_latest),
                .index_version = index_pv,
            });
        } else {
            var fmt_buf: [128]u8 = undefined;
            const current_formatted = installed_pv.format(&fmt_buf);
            out.print("{s} {s} already up-to-date.\n", .{ name, current_formatted });
            return;
        }
    } else {
        // No specific formula — scan all installed for outdated ones.
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

            const installed_pv = PkgVersion.parse(formula.latestVersion());
            const index_pv = PkgVersion{
                .version = index.getString(entry.version_offset),
                .revision = @as(u32, entry.revision),
            };

            if (installed_pv.order(index_pv) == .lt) {
                try to_upgrade.append(allocator, .{
                    .name = try allocator.dupe(u8, formula.name),
                    .installed_version = try allocator.dupe(u8, formula.latestVersion()),
                    .index_version = index_pv,
                });
            }
        }
    }

    // Nothing to upgrade.
    if (to_upgrade.items.len == 0) {
        out.print("Already up-to-date.\n", .{});
        return;
    }

    // Print summary of what will be upgraded.
    const count_str = try std.fmt.allocPrint(allocator, "Upgrading {d} outdated package{s}", .{
        to_upgrade.items.len,
        if (to_upgrade.items.len == 1) "" else "s",
    });
    defer allocator.free(count_str);
    out.section(count_str);

    for (to_upgrade.items) |item| {
        var fmt_buf: [128]u8 = undefined;
        const new_formatted = item.index_version.format(&fmt_buf);
        out.print("{s} {s} -> {s}\n", .{ item.name, item.installed_version, new_formatted });
    }

    // Resolve the brew binary path.
    const brew_path = fallback.findBrewPath(allocator) orelse {
        err_out.err("Could not find a brew executable to delegate upgrade.", .{});
        return error.BrewNotFound;
    };

    // Delegate each upgrade to brew.
    for (to_upgrade.items) |item| {
        var fmt_buf: [128]u8 = undefined;
        const new_formatted = item.index_version.format(&fmt_buf);

        const title = try std.fmt.allocPrint(allocator, "Upgrading {s} {s} -> {s}", .{
            item.name,
            item.installed_version,
            new_formatted,
        });
        defer allocator.free(title);
        out.section(title);

        const argv = [_][]const u8{ brew_path, "upgrade", item.name };
        var child = std.process.Child.init(&argv, allocator);
        const term = try child.spawnAndWait();

        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    err_out.err("brew upgrade {s} exited with status {d}.", .{ item.name, code });
                }
            },
            else => {
                err_out.err("brew upgrade {s} terminated abnormally.", .{item.name});
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "upgradeCmd compiles and has correct signature" {
    // Smoke test: verifies the function signature is correct and the module compiles.
    const handler: @import("../dispatch.zig").CommandFn = upgradeCmd;
    _ = handler;
}
