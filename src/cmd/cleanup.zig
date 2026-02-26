const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const Cellar = @import("../cellar.zig").Cellar;
const Output = @import("../output.zig").Output;

/// Default number of days to retain cached downloads before pruning.
const default_prune_days: u32 = 120;

/// Remove old formula versions from the cellar and stale downloads from the cache.
///
/// Usage: bru cleanup [--dry-run/-n] [--prune=DAYS]
///
/// Without --dry-run, old keg versions and aged cache files are deleted.
/// With --dry-run, only prints what would be removed.
/// --prune=DAYS overrides the default 120-day retention for cache files.
pub fn cleanupCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    // 1. Parse flags.
    var dry_run = false;
    var prune_days: u32 = default_prune_days;

    for (args) |arg| {
        if (mem.eql(u8, arg, "--dry-run") or mem.eql(u8, arg, "-n")) {
            dry_run = true;
        } else if (mem.startsWith(u8, arg, "--prune=")) {
            const value_str = arg["--prune=".len..];
            prune_days = std.fmt.parseInt(u32, value_str, 10) catch default_prune_days;
        }
    }

    const out = Output.init(config.no_color);

    // 2. Clean old versions from cellar.
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

    var versions_removed: u32 = 0;
    for (formulae) |f| {
        if (f.versions.len <= 1) continue;

        // All versions except the last (latest) are old.
        const old_versions = f.versions[0 .. f.versions.len - 1];
        for (old_versions) |version| {
            var keg_buf: [fs.max_path_bytes]u8 = undefined;
            const keg_path = std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ config.cellar, f.name, version }) catch continue;

            if (dry_run) {
                out.print("Would remove: {s}\n", .{keg_path});
            } else {
                out.print("Removing: {s}\n", .{keg_path});
                fs.deleteTreeAbsolute(keg_path) catch |err| {
                    const err_out = Output.initErr(config.no_color);
                    err_out.err("Could not remove {s}: {s}", .{ keg_path, @errorName(err) });
                    continue;
                };
            }
            versions_removed += 1;
        }
    }

    // 3. Clean old downloads from cache.
    var downloads_removed: u32 = 0;
    const max_age_secs: i64 = @as(i64, prune_days) * 86400;

    var cache_path_buf: [fs.max_path_bytes]u8 = undefined;
    const downloads_path = std.fmt.bufPrint(&cache_path_buf, "{s}/downloads", .{config.cache}) catch {
        out.print("Cleaned {d} old downloads.\n", .{downloads_removed});
        return;
    };

    var downloads_dir = fs.openDirAbsolute(downloads_path, .{ .iterate = true }) catch {
        // Downloads directory doesn't exist or can't be opened — nothing to prune.
        if (versions_removed > 0) {
            out.section("Cleanup complete");
        }
        out.print("Cleaned {d} old downloads.\n", .{downloads_removed});
        return;
    };
    defer downloads_dir.close();

    var iter = downloads_dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;

        const file = downloads_dir.openFile(entry.name, .{}) catch continue;
        defer file.close();

        const stat = file.stat() catch continue;
        const mtime_secs: i64 = @intCast(@divFloor(stat.mtime, std.time.ns_per_s));
        const now = std.time.timestamp();
        const age = now - mtime_secs;

        if (age > max_age_secs) {
            if (dry_run) {
                out.print("Would remove: {s}/{s}\n", .{ downloads_path, entry.name });
            } else {
                out.print("Removing: {s}/{s}\n", .{ downloads_path, entry.name });
                downloads_dir.deleteFile(entry.name) catch |err| {
                    const err_out = Output.initErr(config.no_color);
                    err_out.err("Could not remove {s}/{s}: {s}", .{ downloads_path, entry.name, @errorName(err) });
                    continue;
                };
            }
            downloads_removed += 1;
        }
    }

    // 4. Print summary.
    if (versions_removed > 0 or downloads_removed > 0) {
        out.section("Cleanup complete");
    }
    out.print("Cleaned {d} old downloads.\n", .{downloads_removed});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "cleanupCmd compiles and has correct signature" {
    // Smoke test: verifies the function signature is correct and the module compiles.
    const handler: @import("../dispatch.zig").CommandFn = cleanupCmd;
    _ = handler;
}

// Note: dry-run integration test removed — writing to stdout during tests
// corrupts zig build test's IPC protocol. Use test/compat/compare.sh instead.
