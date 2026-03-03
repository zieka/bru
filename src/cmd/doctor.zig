const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const posix = std.posix;
const Allocator = mem.Allocator;
const Config = @import("../config.zig").Config;
const Output = @import("../output.zig").Output;
const Cellar = @import("../cellar.zig").Cellar;

/// Standard prefix subdirectories managed by Homebrew (same as linker.zig).
const managed_dirs = [_][]const u8{ "bin", "sbin", "lib", "include", "share", "etc", "var" };

/// Diagnose system issues and report problems with the Homebrew installation.
pub fn doctorCmd(allocator: Allocator, _: []const []const u8, config: Config) anyerror!void {
    const out = Output.init(config.no_color);
    var warning_count: u32 = 0;

    warning_count += checkPath(config.prefix);
    warning_count += checkBrokenSymlinks(allocator, config.prefix, out);
    warning_count += checkUnlinkedKegs(allocator, config.prefix, config.cellar, out);
    warning_count += checkStaleLockFiles(allocator, config.cellar, config.cache, out);
    warning_count += checkJunkFiles(allocator, config.prefix, out);
    warning_count += checkDirectoryPermissions(config.prefix, out);

    if (warning_count == 0) {
        out.print("Your system is ready to brew.\n", .{});
    }
}

// -----------------------------------------------------------------------
// Check: PATH contains {prefix}/bin and {prefix}/sbin
// -----------------------------------------------------------------------

fn checkPath(prefix: []const u8) u32 {
    const out = Output.initErr(false);
    const path_env = posix.getenv("PATH") orelse {
        out.warn("$PATH is not set.", .{});
        return 1;
    };

    var warnings: u32 = 0;

    var bin_buf: [fs.max_path_bytes]u8 = undefined;
    const bin_path = std.fmt.bufPrint(&bin_buf, "{s}/bin", .{prefix}) catch return 0;
    if (!pathContains(path_env, bin_path)) {
        out.warn("{s} is not in your PATH.", .{bin_path});
        warnings += 1;
    }

    var sbin_buf: [fs.max_path_bytes]u8 = undefined;
    const sbin_path = std.fmt.bufPrint(&sbin_buf, "{s}/sbin", .{prefix}) catch return warnings;
    if (!pathContains(path_env, sbin_path)) {
        out.warn("{s} is not in your PATH.", .{sbin_path});
        warnings += 1;
    }

    return warnings;
}

/// Check whether a PATH-style colon-separated string contains the given directory.
fn pathContains(path_env: []const u8, dir: []const u8) bool {
    var it = mem.splitScalar(u8, path_env, ':');
    while (it.next()) |component| {
        if (mem.eql(u8, component, dir)) return true;
    }
    return false;
}

// -----------------------------------------------------------------------
// Check: broken symlinks in managed prefix directories
// -----------------------------------------------------------------------

fn checkBrokenSymlinks(allocator: Allocator, prefix: []const u8, out: Output) u32 {
    var broken = std.ArrayList([]const u8){};
    defer {
        for (broken.items) |s| allocator.free(s);
        broken.deinit(allocator);
    }

    for (managed_dirs) |dir| {
        var dir_buf: [fs.max_path_bytes]u8 = undefined;
        const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ prefix, dir }) catch continue;
        collectBrokenSymlinks(allocator, &broken, dir_path);
    }

    if (broken.items.len == 0) return 0;

    out.warn("Broken symlinks were found:", .{});
    for (broken.items) |path| {
        out.print("  {s}\n", .{path});
    }
    out.print("\n", .{});
    return 1;
}

fn collectBrokenSymlinks(allocator: Allocator, broken: *std.ArrayList([]const u8), dir_path: []const u8) void {
    var dir = fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .sym_link) {
            // Try to stat the target — if it fails, the symlink is broken.
            var full_buf: [fs.max_path_bytes]u8 = undefined;
            const full_path = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;

            _ = fs.openFileAbsolute(full_path, .{}) catch |err| {
                if (err == error.FileNotFound) {
                    const duped = allocator.dupe(u8, full_path) catch continue;
                    broken.append(allocator, duped) catch {
                        allocator.free(duped);
                        continue;
                    };
                }
                continue;
            };
        } else if (entry.kind == .directory) {
            var sub_buf: [fs.max_path_bytes]u8 = undefined;
            const sub_path = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
            collectBrokenSymlinks(allocator, broken, sub_path);
        }
    }
}

// -----------------------------------------------------------------------
// Check: unlinked kegs (kegs in Cellar with no opt symlink)
// -----------------------------------------------------------------------

fn checkUnlinkedKegs(allocator: Allocator, prefix: []const u8, cellar: []const u8, out: Output) u32 {
    const cellar_obj = Cellar.init(cellar);
    const formulae = cellar_obj.installedFormulae(allocator);
    defer {
        for (formulae) |f| {
            for (f.versions) |v| allocator.free(v);
            allocator.free(f.versions);
            allocator.free(f.name);
        }
        allocator.free(formulae);
    }

    var unlinked = std.ArrayList([]const u8){};
    defer unlinked.deinit(allocator);

    for (formulae) |f| {
        var opt_buf: [fs.max_path_bytes]u8 = undefined;
        const opt_path = std.fmt.bufPrint(&opt_buf, "{s}/opt/{s}", .{ prefix, f.name }) catch continue;

        // Check if the opt symlink exists and is a valid symlink.
        var read_buf: [fs.max_path_bytes]u8 = undefined;
        _ = fs.readLinkAbsolute(opt_path, &read_buf) catch {
            // No opt symlink — this keg is unlinked.
            unlinked.append(allocator, f.name) catch continue;
            continue;
        };
    }

    if (unlinked.items.len == 0) return 0;

    out.warn("You have unlinked kegs in your Cellar.", .{});
    out.print("Leaving kegs unlinked can lead to build-trouble and cause formulae that depend on\n", .{});
    out.print("each other to fail to work correctly.\n", .{});
    out.print("Run `bru link` on these:\n", .{});
    for (unlinked.items) |name| {
        out.print("  {s}\n", .{name});
    }
    out.print("\n", .{});
    return 1;
}

// -----------------------------------------------------------------------
// Check: stale lock files in Cellar and cache
// -----------------------------------------------------------------------

fn checkStaleLockFiles(allocator: Allocator, cellar: []const u8, cache: []const u8, out: Output) u32 {
    var stale = std.ArrayList([]const u8){};
    defer {
        for (stale.items) |s| allocator.free(s);
        stale.deinit(allocator);
    }

    // Check for .lock files directly in cache directory (not recursive).
    collectLockFilesFlat(allocator, &stale, cache);

    // Check for .lock files in cellar at formula level: {cellar}/{name}/*.lock
    collectCellarLockFiles(allocator, &stale, cellar);

    if (stale.items.len == 0) return 0;

    out.warn("Stale lock files were found:", .{});
    for (stale.items) |path| {
        out.print("  {s}\n", .{path});
    }
    out.print("You should remove them with:\n", .{});
    for (stale.items) |path| {
        out.print("  rm -f {s}\n", .{path});
    }
    out.print("\n", .{});
    return 1;
}

/// Collect .lock files directly in a directory (non-recursive).
fn collectLockFilesFlat(allocator: Allocator, stale: *std.ArrayList([]const u8), dir_path: []const u8) void {
    var dir = fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory and mem.endsWith(u8, entry.name, ".lock")) {
            var full_buf: [fs.max_path_bytes]u8 = undefined;
            const full_path = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
            const duped = allocator.dupe(u8, full_path) catch continue;
            stale.append(allocator, duped) catch {
                allocator.free(duped);
            };
        }
    }
}

/// Collect .lock files at the formula level inside the cellar:
/// {cellar}/{formula_name}/*.lock
fn collectCellarLockFiles(allocator: Allocator, stale: *std.ArrayList([]const u8), cellar: []const u8) void {
    var dir = fs.openDirAbsolute(cellar, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .directory or entry.kind == .unknown) {
            var sub_buf: [fs.max_path_bytes]u8 = undefined;
            const sub_path = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ cellar, entry.name }) catch continue;
            collectLockFilesFlat(allocator, stale, sub_path);
        }
    }
}

// -----------------------------------------------------------------------
// Check: junk files (.DS_Store) in managed directories
// -----------------------------------------------------------------------

fn checkJunkFiles(allocator: Allocator, prefix: []const u8, out: Output) u32 {
    var junk = std.ArrayList([]const u8){};
    defer {
        for (junk.items) |s| allocator.free(s);
        junk.deinit(allocator);
    }

    for (managed_dirs) |dir| {
        var dir_buf: [fs.max_path_bytes]u8 = undefined;
        const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ prefix, dir }) catch continue;
        collectJunkFiles(allocator, &junk, dir_path);
    }

    // Also check the prefix root itself.
    collectJunkFilesFlat(allocator, &junk, prefix);

    if (junk.items.len == 0) return 0;

    out.warn("Unexpected .DS_Store files were found:", .{});
    for (junk.items) |path| {
        out.print("  {s}\n", .{path});
    }
    out.print("You should remove them:\n", .{});
    out.print("  find {s} -name .DS_Store -delete\n", .{prefix});
    out.print("\n", .{});
    return 1;
}

fn collectJunkFiles(allocator: Allocator, junk: *std.ArrayList([]const u8), dir_path: []const u8) void {
    var dir = fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (mem.eql(u8, entry.name, ".DS_Store")) {
            var full_buf: [fs.max_path_bytes]u8 = undefined;
            const full_path = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
            const duped = allocator.dupe(u8, full_path) catch continue;
            junk.append(allocator, duped) catch {
                allocator.free(duped);
            };
        } else if (entry.kind == .directory) {
            var sub_buf: [fs.max_path_bytes]u8 = undefined;
            const sub_path = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
            collectJunkFiles(allocator, junk, sub_path);
        }
    }
}

fn collectJunkFilesFlat(allocator: Allocator, junk: *std.ArrayList([]const u8), dir_path: []const u8) void {
    var dir = fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (mem.eql(u8, entry.name, ".DS_Store")) {
            var full_buf: [fs.max_path_bytes]u8 = undefined;
            const full_path = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
            const duped = allocator.dupe(u8, full_path) catch continue;
            junk.append(allocator, duped) catch {
                allocator.free(duped);
            };
        }
    }
}

// -----------------------------------------------------------------------
// Check: directory permissions
// -----------------------------------------------------------------------

fn checkDirectoryPermissions(prefix: []const u8, out: Output) u32 {
    // max_dirs: prefix + 7 managed + 2 extra (Cellar, opt)
    var unwritable_buf: [10][]const u8 = undefined;
    var unwritable_len: usize = 0;

    // Check prefix root.
    if (!isWritable(prefix)) {
        unwritable_buf[unwritable_len] = prefix;
        unwritable_len += 1;
    }

    // Check managed subdirectories.
    // We need stable storage for formatted paths since bufPrint reuses the buffer.
    var path_storage: [10][fs.max_path_bytes]u8 = undefined;
    var storage_idx: usize = 0;

    for (managed_dirs) |dir| {
        if (storage_idx >= path_storage.len) break;
        const dir_path = std.fmt.bufPrint(&path_storage[storage_idx], "{s}/{s}", .{ prefix, dir }) catch continue;
        // Only check if it exists.
        fs.accessAbsolute(dir_path, .{}) catch continue;
        if (!isWritable(dir_path)) {
            unwritable_buf[unwritable_len] = dir_path;
            unwritable_len += 1;
            storage_idx += 1;
        }
    }

    // Also check Cellar and opt.
    const extra_dirs = [_][]const u8{ "Cellar", "opt" };
    for (extra_dirs) |dir| {
        if (storage_idx >= path_storage.len) break;
        const dir_path = std.fmt.bufPrint(&path_storage[storage_idx], "{s}/{s}", .{ prefix, dir }) catch continue;
        fs.accessAbsolute(dir_path, .{}) catch continue;
        if (!isWritable(dir_path)) {
            unwritable_buf[unwritable_len] = dir_path;
            unwritable_len += 1;
            storage_idx += 1;
        }
    }

    if (unwritable_len == 0) return 0;

    const unwritable = unwritable_buf[0..unwritable_len];
    out.warn("The following directories are not writable by your user:", .{});
    for (unwritable) |path| {
        out.print("  {s}\n", .{path});
    }
    out.print("You should change the ownership of these directories to your user.\n", .{});
    out.print("  sudo chown -R $(whoami) {s}\n", .{unwritable[0]});
    out.print("\n", .{});
    return 1;
}

fn isWritable(path: []const u8) bool {
    posix.access(path, posix.W_OK) catch return false;
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "doctorCmd compiles and has correct signature" {
    const handler: @import("../dispatch.zig").CommandFn = doctorCmd;
    _ = handler;
}

test "pathContains finds exact match" {
    try std.testing.expect(pathContains("/usr/bin:/opt/homebrew/bin:/usr/sbin", "/opt/homebrew/bin"));
}

test "pathContains rejects partial match" {
    try std.testing.expect(!pathContains("/usr/bin:/opt/homebrew/binary:/usr/sbin", "/opt/homebrew/bin"));
}

test "pathContains handles single entry" {
    try std.testing.expect(pathContains("/opt/homebrew/bin", "/opt/homebrew/bin"));
}

test "pathContains rejects empty PATH" {
    try std.testing.expect(!pathContains("", "/opt/homebrew/bin"));
}

test "isWritable returns true for temp dir" {
    try std.testing.expect(isWritable("/tmp"));
}
