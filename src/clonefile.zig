const std = @import("std");
const fs = std.fs;
const posix = std.posix;
const builtin = @import("builtin");

/// Clone a directory tree from `src_path` to `dst_path`.
///
/// On macOS, tries `clonefile()` first (instant on APFS — metadata-only copy).
/// Apple recommends `copyfile(3)` for directory trees, but `clonefile()` works
/// on APFS and is a single syscall with no overhead. If a future macOS version
/// rejects directory clonefile, the recursive copy fallback handles it.
///
/// Falls back to a recursive copy when clonefile is unsupported (e.g. cross-device,
/// non-APFS filesystem, or non-macOS platform).
///
/// Returns `true` if clonefile succeeded, `false` if the fallback copy was used.
pub fn cloneTree(src_path: []const u8, dst_path: []const u8) !bool {
    if (comptime builtin.os.tag == .macos) {
        // macOS clonefile() syscall — not exposed by Zig's std library.
        const c = struct {
            extern "c" fn clonefile(src: [*:0]const u8, dst: [*:0]const u8, flags: c_uint) c_int;
        };
        const CLONE_NOFOLLOW: c_uint = 0x0001;

        // Build sentinel-terminated path buffers for the C call.
        var src_buf: [fs.max_path_bytes:0]u8 = undefined;
        var dst_buf: [fs.max_path_bytes:0]u8 = undefined;

        if (src_path.len >= fs.max_path_bytes) return error.NameTooLong;
        if (dst_path.len >= fs.max_path_bytes) return error.NameTooLong;

        @memcpy(src_buf[0..src_path.len], src_path);
        src_buf[src_path.len] = 0;

        @memcpy(dst_buf[0..dst_path.len], dst_path);
        dst_buf[dst_path.len] = 0;

        const rc = c.clonefile(&src_buf, &dst_buf, CLONE_NOFOLLOW);
        if (rc == 0) return true;

        // clonefile() is a C library function: returns -1 on error and sets
        // the C thread-local errno. Read it directly (not via posix.errno
        // which is for Linux-style raw syscall return values).
        const e: posix.E = @enumFromInt(std.c._errno().*);

        switch (e) {
            // Source does not exist.
            .NOENT => return error.FileNotFound,
            // Destination already exists.
            .EXIST => return error.PathAlreadyExists,
            // Filesystem doesn't support clonefile or cross-device: fall back.
            .OPNOTSUPP, .XDEV => {},
            // Any other error is unexpected — propagate it.
            else => return error.ClonefileFailed,
        }
    }

    // Fallback: recursive copy (also the only path on non-macOS).
    try recursiveCopy(src_path, dst_path);
    return false;
}

/// Recursively copy a directory tree, preserving symlinks and file permissions.
fn recursiveCopy(src_path: []const u8, dst_path: []const u8) !void {
    // Stat the source to determine its type (without following symlinks).
    const src_stat = fs.cwd().statFile(src_path) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return error.CopyFailed,
    };

    if (src_stat.kind == .directory) {
        // Create the destination directory.
        fs.makeDirAbsolute(dst_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return error.CopyFailed,
        };

        // Iterate source directory entries.
        var src_dir = fs.openDirAbsolute(src_path, .{ .iterate = true }) catch return error.CopyFailed;
        defer src_dir.close();

        var iter = src_dir.iterate();
        while (iter.next() catch return error.CopyFailed) |entry| {
            var child_src_buf: [fs.max_path_bytes]u8 = undefined;
            const child_src = std.fmt.bufPrint(&child_src_buf, "{s}/{s}", .{ src_path, entry.name }) catch
                return error.NameTooLong;

            var child_dst_buf: [fs.max_path_bytes]u8 = undefined;
            const child_dst = std.fmt.bufPrint(&child_dst_buf, "{s}/{s}", .{ dst_path, entry.name }) catch
                return error.NameTooLong;

            switch (entry.kind) {
                .directory => try recursiveCopy(child_src, child_dst),
                .sym_link => try copySymlink(src_dir, entry.name, child_dst),
                else => try copyRegularFile(src_path, entry.name, dst_path),
            }
        }
    } else {
        return error.CopyFailed;
    }
}

/// Recreate a symlink: read the target from the source and create an identical
/// symlink at the destination path.
fn copySymlink(src_dir: fs.Dir, name: []const u8, dst_path: []const u8) !void {
    var target_buf: [fs.max_path_bytes]u8 = undefined;
    const target = src_dir.readLink(name, &target_buf) catch return error.CopyFailed;

    // Extract the parent directory and basename from dst_path.
    const dirname = std.fs.path.dirname(dst_path) orelse return error.CopyFailed;
    const basename = std.fs.path.basename(dst_path);

    var dir = fs.openDirAbsolute(dirname, .{}) catch return error.CopyFailed;
    defer dir.close();

    dir.symLink(target, basename, .{}) catch return error.CopyFailed;
}

/// Copy a regular file from src_dir/name to dst_dir/name, preserving permissions.
fn copyRegularFile(src_dir_path: []const u8, name: []const u8, dst_dir_path: []const u8) !void {
    var src_dir = fs.openDirAbsolute(src_dir_path, .{}) catch return error.CopyFailed;
    defer src_dir.close();

    var dst_dir = fs.openDirAbsolute(dst_dir_path, .{}) catch return error.CopyFailed;
    defer dst_dir.close();

    // copyFile with null override_mode preserves the source file's permissions.
    dst_dir.copyFile(name, src_dir, name, .{}) catch return error.CopyFailed;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "cloneTree copies directory with files" {
    // Create a source directory with files.
    var tmp_src = std.testing.tmpDir(.{});
    defer tmp_src.cleanup();

    // Create some files.
    {
        var f = try tmp_src.dir.createFile("hello.txt", .{});
        defer f.close();
        var write_buf: [4096]u8 = undefined;
        var w = f.writer(&write_buf);
        try w.interface.writeAll("hello world");
        try w.interface.flush();
    }
    try tmp_src.dir.makeDir("subdir");
    {
        var f = try tmp_src.dir.createFile("subdir/nested.txt", .{});
        defer f.close();
        var write_buf: [4096]u8 = undefined;
        var w = f.writer(&write_buf);
        try w.interface.writeAll("nested content");
        try w.interface.flush();
    }

    // Get real paths.
    var src_buf: [fs.max_path_bytes]u8 = undefined;
    const src_path = try tmp_src.dir.realpath(".", &src_buf);

    // Create a sibling destination path (in the same tmp area so clonefile should work).
    var tmp_parent = std.testing.tmpDir(.{});
    defer tmp_parent.cleanup();

    var dst_buf: [fs.max_path_bytes]u8 = undefined;
    const parent_path = try tmp_parent.dir.realpath(".", &dst_buf);

    var dst_path_buf: [fs.max_path_bytes]u8 = undefined;
    const dst_path = try std.fmt.bufPrint(&dst_path_buf, "{s}/clone_dest", .{parent_path});

    const used_clonefile = try cloneTree(src_path, dst_path);
    _ = used_clonefile; // Either path is fine — we verify contents below.

    // Verify top-level file.
    var dst_dir = try fs.openDirAbsolute(dst_path, .{});
    defer dst_dir.close();

    {
        var f = try dst_dir.openFile("hello.txt", .{});
        defer f.close();
        var content_buf: [256]u8 = undefined;
        const n = try f.readAll(&content_buf);
        try std.testing.expectEqualStrings("hello world", content_buf[0..n]);
    }

    // Verify nested file.
    {
        var f = try dst_dir.openFile("subdir/nested.txt", .{});
        defer f.close();
        var content_buf: [256]u8 = undefined;
        const n = try f.readAll(&content_buf);
        try std.testing.expectEqualStrings("nested content", content_buf[0..n]);
    }
}

test "cloneTree preserves symlinks" {
    var tmp_src = std.testing.tmpDir(.{});
    defer tmp_src.cleanup();

    // Create a file and a symlink to it.
    {
        var f = try tmp_src.dir.createFile("target.txt", .{});
        defer f.close();
        var write_buf: [4096]u8 = undefined;
        var w = f.writer(&write_buf);
        try w.interface.writeAll("target content");
        try w.interface.flush();
    }
    try tmp_src.dir.symLink("target.txt", "link.txt", .{});

    var src_buf: [fs.max_path_bytes]u8 = undefined;
    const src_path = try tmp_src.dir.realpath(".", &src_buf);

    var tmp_parent = std.testing.tmpDir(.{});
    defer tmp_parent.cleanup();

    var parent_buf: [fs.max_path_bytes]u8 = undefined;
    const parent_path = try tmp_parent.dir.realpath(".", &parent_buf);

    var dst_path_buf: [fs.max_path_bytes]u8 = undefined;
    const dst_path = try std.fmt.bufPrint(&dst_path_buf, "{s}/clone_dest", .{parent_path});

    _ = try cloneTree(src_path, dst_path);

    // Verify the symlink exists and points to the correct target.
    var dst_dir = try fs.openDirAbsolute(dst_path, .{});
    defer dst_dir.close();

    var link_target_buf: [fs.max_path_bytes]u8 = undefined;
    const link_target = try dst_dir.readLink("link.txt", &link_target_buf);
    try std.testing.expectEqualStrings("target.txt", link_target);
}

test "cloneTree fails with FileNotFound when source doesn't exist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var tmp_buf: [fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &tmp_buf);

    var src_buf: [fs.max_path_bytes]u8 = undefined;
    const src_path = try std.fmt.bufPrint(&src_buf, "{s}/nonexistent_source", .{tmp_path});

    var dst_buf: [fs.max_path_bytes]u8 = undefined;
    const dst_path = try std.fmt.bufPrint(&dst_buf, "{s}/nonexistent_dest", .{tmp_path});

    const result = cloneTree(src_path, dst_path);
    try std.testing.expectError(error.FileNotFound, result);
}
