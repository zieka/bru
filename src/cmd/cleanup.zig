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
    const err_out = Output.initErr(config.no_color);

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
                    err_out.err("Could not remove {s}: {s}", .{ keg_path, @errorName(err) });
                    continue;
                };
            }
            versions_removed += 1;
        }
    }

    // 3. Clean old downloads, blobs, and keg cache entries.
    const max_age_secs: i64 = @as(i64, prune_days) * 86400;

    // 3a. Legacy downloads (files in {cache}/downloads/).
    const downloads_removed = pruneOldFiles(config.cache, "downloads", max_age_secs, dry_run, out, err_out);

    // 3b. Content-addressable blobs (files in {cache}/blobs/).
    const blobs_removed = pruneOldFiles(config.cache, "blobs", max_age_secs, dry_run, out, err_out);

    // 3c. Extracted keg cache (directories in {cache}/kegs/).
    const kegs_removed = pruneOldDirs(config.cache, "kegs", max_age_secs, dry_run, out, err_out);

    // 4. Print summary.
    const total_cache = downloads_removed + blobs_removed + kegs_removed;
    if (versions_removed > 0 or total_cache > 0) {
        out.section("Cleanup complete");
    }
    if (versions_removed > 0) {
        out.print("Removed {d} old version{s}.\n", .{
            versions_removed,
            if (versions_removed == 1) "" else "s",
        });
    }
    if (total_cache > 0) {
        out.print("Removed {d} cached file{s}.\n", .{
            total_cache,
            if (total_cache == 1) "" else "s",
        });
    }
    if (versions_removed == 0 and total_cache == 0) {
        out.print("Already clean.\n", .{});
    }
}

/// Prune files older than max_age_secs from {cache}/{subdir}/.
fn pruneOldFiles(
    cache: []const u8,
    subdir: []const u8,
    max_age_secs: i64,
    dry_run: bool,
    out: Output,
    err_out: Output,
) u32 {
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ cache, subdir }) catch return 0;

    var dir = fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close();

    var removed: u32 = 0;
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;

        const file = dir.openFile(entry.name, .{}) catch continue;
        defer file.close();

        const stat = file.stat() catch continue;
        const mtime_secs: i64 = @intCast(@divFloor(stat.mtime, std.time.ns_per_s));
        const age = std.time.timestamp() - mtime_secs;

        if (age > max_age_secs) {
            if (dry_run) {
                out.print("Would remove: {s}/{s}\n", .{ dir_path, entry.name });
            } else {
                out.print("Removing: {s}/{s}\n", .{ dir_path, entry.name });
                dir.deleteFile(entry.name) catch |err| {
                    err_out.err("Could not remove {s}/{s}: {s}", .{ dir_path, entry.name, @errorName(err) });
                    continue;
                };
            }
            removed += 1;
        }
    }
    return removed;
}

/// Prune directories older than max_age_secs from {cache}/{subdir}/.
fn pruneOldDirs(
    cache: []const u8,
    subdir: []const u8,
    max_age_secs: i64,
    dry_run: bool,
    out: Output,
    err_out: Output,
) u32 {
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ cache, subdir }) catch return 0;

    var dir = fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close();

    var removed: u32 = 0;
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;

        // Check mtime of the directory itself.
        var sub_dir = dir.openDir(entry.name, .{}) catch continue;
        const stat = sub_dir.stat() catch {
            sub_dir.close();
            continue;
        };
        sub_dir.close();

        const mtime_secs: i64 = @intCast(@divFloor(stat.mtime, std.time.ns_per_s));
        const age = std.time.timestamp() - mtime_secs;

        if (age > max_age_secs) {
            var full_buf: [fs.max_path_bytes]u8 = undefined;
            const full_path = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;

            if (dry_run) {
                out.print("Would remove: {s}\n", .{full_path});
            } else {
                out.print("Removing: {s}\n", .{full_path});
                fs.deleteTreeAbsolute(full_path) catch |err| {
                    err_out.err("Could not remove {s}: {s}", .{ full_path, @errorName(err) });
                    continue;
                };
            }
            removed += 1;
        }
    }
    return removed;
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
