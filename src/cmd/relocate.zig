const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const Cellar = @import("../cellar.zig").Cellar;
const Bottle = @import("../bottle.zig").Bottle;
const Output = @import("../output.zig").Output;

/// `bru relocate [name...]`: re-run placeholder replacement and Mach-O load
/// command relocation on installed kegs. Repairs kegs whose dylibs still
/// contain literal @@HOMEBREW_PREFIX@@ paths (for example, after a pre-fix
/// `bru upgrade` that skipped the relocation step).
///
/// With no arguments, sweeps every installed formula in the cellar. With one
/// or more formula names, processes only those.
pub fn relocateCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    const out = Output.init(config.no_color);
    const err_out = Output.initErr(config.no_color);

    const bottle = Bottle.init(allocator, config);

    var ok: usize = 0;
    var fail: usize = 0;

    if (args.len == 0) {
        const cellar = Cellar.init(config.cellar);
        const formulae = cellar.installedFormulae(allocator);
        defer {
            for (formulae) |f| {
                for (f.versions) |v| allocator.free(v);
                allocator.free(f.versions);
                allocator.free(f.name);
            }
            allocator.free(formulae);
        }

        if (formulae.len == 0) {
            out.print("No installed formulae found in {s}.\n", .{config.cellar});
            return;
        }

        out.section("Relocating all installed formulae");
        for (formulae) |f| {
            if (relocateOne(allocator, bottle, config, f.name, out, err_out)) ok += 1 else fail += 1;
        }
    } else {
        for (args) |name| {
            if (relocateOne(allocator, bottle, config, name, out, err_out)) ok += 1 else fail += 1;
        }
    }

    out.print("Relocated {d} keg(s)", .{ok});
    if (fail > 0) out.print(", {d} failed", .{fail});
    out.print(".\n", .{});
}

/// Relocate every installed version of `name`. Returns true if at least one
/// keg was processed successfully, false if the formula is not installed or
/// every version failed.
fn relocateOne(
    allocator: Allocator,
    bottle: Bottle,
    config: Config,
    name: []const u8,
    out: Output,
    err_out: Output,
) bool {
    const cellar = Cellar.init(config.cellar);
    const versions = cellar.installedVersions(allocator, name) orelse {
        err_out.warn("{s} is not installed.", .{name});
        return false;
    };
    defer {
        for (versions) |v| allocator.free(v);
        allocator.free(versions);
    }

    var any_ok = false;
    for (versions) |version| {
        const keg_path = std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{
            config.cellar,
            name,
            version,
        }) catch {
            err_out.warn("{s} {s}: out of memory building keg path", .{ name, version });
            continue;
        };
        defer allocator.free(keg_path);

        out.print("==> {s} {s}\n", .{ name, version });

        bottle.replacePlaceholders(keg_path) catch |err| {
            err_out.warn("{s} {s}: replacePlaceholders failed: {s}", .{ name, version, @errorName(err) });
            continue;
        };
        bottle.relocateMachO(keg_path) catch |err| {
            err_out.warn("{s} {s}: relocateMachO failed: {s}", .{ name, version, @errorName(err) });
            continue;
        };
        any_ok = true;
    }

    return any_ok;
}
