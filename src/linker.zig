const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const Allocator = mem.Allocator;

/// Keg linker: symlinks keg contents into the Homebrew prefix.
pub const Linker = struct {
    prefix: []const u8,
    allocator: Allocator,

    /// Standard directories to link from a keg into the prefix.
    const std_dirs = [_][]const u8{ "bin", "sbin", "lib", "include", "share", "etc", "var" };

    pub fn init(allocator: Allocator, prefix: []const u8) Linker {
        return .{ .prefix = prefix, .allocator = allocator };
    }

    /// Create opt link: $PREFIX/opt/{name} -> keg_path
    pub fn optLink(self: Linker, name: []const u8, keg_path: []const u8) !void {
        var opt_dir_buf: [fs.max_path_bytes]u8 = undefined;
        const opt_dir = try std.fmt.bufPrint(&opt_dir_buf, "{s}/opt", .{self.prefix});

        fs.makeDirAbsolute(opt_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        var link_buf: [fs.max_path_bytes]u8 = undefined;
        const link_path = try std.fmt.bufPrint(&link_buf, "{s}/opt/{s}", .{ self.prefix, name });

        // Remove any existing file/symlink at the opt path.
        fs.deleteFileAbsolute(link_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        try fs.symLinkAbsolute(keg_path, link_path, .{});
    }

    /// Link all keg contents into prefix.
    pub fn link(self: Linker, name: []const u8, keg_path: []const u8) !void {
        try self.optLink(name, keg_path);

        for (std_dirs) |dir| {
            // Check if {keg_path}/{dir} exists.
            var keg_dir_buf: [fs.max_path_bytes]u8 = undefined;
            const keg_dir_path = std.fmt.bufPrint(&keg_dir_buf, "{s}/{s}", .{ keg_path, dir }) catch continue;

            var keg_dir = fs.openDirAbsolute(keg_dir_path, .{ .iterate = true }) catch continue;
            defer keg_dir.close();

            // Ensure {prefix}/{dir} exists.
            var prefix_dir_buf: [fs.max_path_bytes]u8 = undefined;
            const prefix_dir_path = std.fmt.bufPrint(&prefix_dir_buf, "{s}/{s}", .{ self.prefix, dir }) catch continue;

            fs.makeDirAbsolute(prefix_dir_path) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => continue,
            };

            // Strategy depends on directory type.
            if (mem.eql(u8, dir, "bin") or mem.eql(u8, dir, "sbin")) {
                self.linkFlat(keg_dir, keg_dir_path, prefix_dir_path) catch continue;
            } else {
                // etc, lib, include, share, var: recursive file linking
                self.linkRecursive(keg_dir, keg_dir_path, prefix_dir_path) catch continue;
            }
        }
    }

    /// Remove all symlinks from prefix that point into the given keg.
    pub fn unlink(self: Linker, keg_path: []const u8) !void {
        // Walk each standard directory in prefix and remove symlinks pointing into keg_path.
        for (std_dirs) |dir| {
            var prefix_dir_buf: [fs.max_path_bytes]u8 = undefined;
            const prefix_dir_path = std.fmt.bufPrint(&prefix_dir_buf, "{s}/{s}", .{ self.prefix, dir }) catch continue;

            self.unlinkRecursive(prefix_dir_path, keg_path) catch continue;
        }

        // Also remove the opt link.
        // Parse name from keg_path: {cellar}/{name}/{version}
        // The name is the second-to-last path component.
        if (parseKegName(keg_path)) |name| {
            var opt_link_buf: [fs.max_path_bytes]u8 = undefined;
            const opt_link_path = std.fmt.bufPrint(&opt_link_buf, "{s}/opt/{s}", .{ self.prefix, name }) catch return;

            // Only remove if it's a symlink pointing into this keg.
            var read_buf: [fs.max_path_bytes]u8 = undefined;
            const target = fs.readLinkAbsolute(opt_link_path, &read_buf) catch return;
            if (mem.startsWith(u8, target, keg_path)) {
                fs.deleteFileAbsolute(opt_link_path) catch {};
            }
        }
    }

    // -- Private helpers --

    /// Flat linking: symlink files only, skip subdirectories.
    fn linkFlat(self: Linker, keg_dir: fs.Dir, keg_dir_path: []const u8, prefix_dir_path: []const u8) !void {
        _ = self;
        var iter = keg_dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .directory) continue;

            var src_buf: [fs.max_path_bytes]u8 = undefined;
            const src = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ keg_dir_path, entry.name }) catch continue;

            var dst_buf: [fs.max_path_bytes]u8 = undefined;
            const dst = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ prefix_dir_path, entry.name }) catch continue;

            // Remove existing and create symlink.
            fs.deleteFileAbsolute(dst) catch |err| switch (err) {
                error.FileNotFound => {},
                else => continue,
            };
            fs.symLinkAbsolute(src, dst, .{}) catch continue;
        }
    }

    /// Recursive linking: create real directories in prefix, symlink files.
    /// Used for etc/, lib/, include/, share/, var/.
    fn linkRecursive(self: Linker, keg_dir: fs.Dir, keg_dir_path: []const u8, prefix_dir_path: []const u8) !void {
        var iter = keg_dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .directory) {
                var sub_keg_buf: [fs.max_path_bytes]u8 = undefined;
                const sub_keg = std.fmt.bufPrint(&sub_keg_buf, "{s}/{s}", .{ keg_dir_path, entry.name }) catch continue;

                var sub_prefix_buf: [fs.max_path_bytes]u8 = undefined;
                const sub_prefix = std.fmt.bufPrint(&sub_prefix_buf, "{s}/{s}", .{ prefix_dir_path, entry.name }) catch continue;

                fs.makeDirAbsolute(sub_prefix) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => continue,
                };

                var sub_dir = keg_dir.openDir(entry.name, .{ .iterate = true }) catch continue;
                defer sub_dir.close();

                self.linkRecursive(sub_dir, sub_keg, sub_prefix) catch continue;
            } else {
                var src_buf: [fs.max_path_bytes]u8 = undefined;
                const src = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ keg_dir_path, entry.name }) catch continue;

                var dst_buf: [fs.max_path_bytes]u8 = undefined;
                const dst = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ prefix_dir_path, entry.name }) catch continue;

                fs.deleteFileAbsolute(dst) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => continue,
                };
                fs.symLinkAbsolute(src, dst, .{}) catch continue;
            }
        }
    }

    /// Recursively walk a prefix directory and remove symlinks pointing into keg_path.
    fn unlinkRecursive(self: Linker, dir_path: []const u8, keg_path: []const u8) !void {
        _ = self;
        var dir = fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .sym_link) {
                var full_buf: [fs.max_path_bytes]u8 = undefined;
                const full_path = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;

                var read_buf: [fs.max_path_bytes]u8 = undefined;
                const target = fs.readLinkAbsolute(full_path, &read_buf) catch continue;

                if (mem.startsWith(u8, target, keg_path)) {
                    fs.deleteFileAbsolute(full_path) catch {};
                }
            } else if (entry.kind == .directory) {
                // Recurse into subdirectories.
                var sub_buf: [fs.max_path_bytes]u8 = undefined;
                const sub_path = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;

                // Use a nested call; we need to be careful not to re-use self since
                // unlinkRecursive doesn't actually use self. We call through the function directly.
                unlinkRecursiveStatic(sub_path, keg_path);
            }
        }
    }

    /// Static version of unlinkRecursive (no self needed) to avoid method resolution issues in recursion.
    fn unlinkRecursiveStatic(dir_path: []const u8, keg_path: []const u8) void {
        var dir = fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .sym_link) {
                var full_buf: [fs.max_path_bytes]u8 = undefined;
                const full_path = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;

                var read_buf: [fs.max_path_bytes]u8 = undefined;
                const target = fs.readLinkAbsolute(full_path, &read_buf) catch continue;

                if (mem.startsWith(u8, target, keg_path)) {
                    fs.deleteFileAbsolute(full_path) catch {};
                }
            } else if (entry.kind == .directory) {
                var sub_buf: [fs.max_path_bytes]u8 = undefined;
                const sub_path = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;

                unlinkRecursiveStatic(sub_path, keg_path);
            }
        }
    }
};

/// Parse the formula name from a keg path like "{cellar}/{name}/{version}".
/// Returns the name component, or null if the path doesn't have enough segments.
fn parseKegName(keg_path: []const u8) ?[]const u8 {
    // Find the last slash to get the version component, then the second-to-last
    // slash to get the name.
    const trimmed = mem.trimRight(u8, keg_path, "/");
    const last_slash = mem.lastIndexOfScalar(u8, trimmed, '/') orelse return null;
    const before_version = trimmed[0..last_slash];
    const name_slash = mem.lastIndexOfScalar(u8, before_version, '/') orelse return null;
    return before_version[name_slash + 1 ..];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "optLink creates symlink" {
    var tmp_prefix = std.testing.tmpDir(.{});
    defer tmp_prefix.cleanup();

    // Create opt/ subdir.
    tmp_prefix.dir.makeDir("opt") catch {};

    // Get real path of prefix.
    var prefix_buf: [fs.max_path_bytes]u8 = undefined;
    const prefix_path = try tmp_prefix.dir.realpath(".", &prefix_buf);

    const linker = Linker.init(std.testing.allocator, prefix_path);

    const keg_path = "/opt/homebrew/Cellar/hello/2.10";
    try linker.optLink("hello", keg_path);

    // Verify symlink target.
    var link_buf: [fs.max_path_bytes]u8 = undefined;
    var opt_link_buf: [fs.max_path_bytes]u8 = undefined;
    const opt_link_path = try std.fmt.bufPrint(&opt_link_buf, "{s}/opt/hello", .{prefix_path});
    const target = try fs.readLinkAbsolute(opt_link_path, &link_buf);
    try std.testing.expectEqualStrings(keg_path, target);
}

test "link creates symlinks for bin files" {
    // Create fake prefix.
    var tmp_prefix = std.testing.tmpDir(.{});
    defer tmp_prefix.cleanup();

    // Create fake keg.
    var tmp_keg = std.testing.tmpDir(.{});
    defer tmp_keg.cleanup();

    // Create bin/mytool in keg.
    tmp_keg.dir.makeDir("bin") catch {};
    var f = try tmp_keg.dir.createFile("bin/mytool", .{});
    f.close();

    // Get real paths.
    var prefix_buf: [fs.max_path_bytes]u8 = undefined;
    const prefix_path = try tmp_prefix.dir.realpath(".", &prefix_buf);

    var keg_buf: [fs.max_path_bytes]u8 = undefined;
    const keg_path = try tmp_keg.dir.realpath(".", &keg_buf);

    const linker = Linker.init(std.testing.allocator, prefix_path);
    try linker.link("mytool", keg_path);

    // Verify {prefix}/bin/mytool is a symlink to {keg}/bin/mytool.
    var link_path_buf: [fs.max_path_bytes]u8 = undefined;
    const link_path = try std.fmt.bufPrint(&link_path_buf, "{s}/bin/mytool", .{prefix_path});

    var read_buf: [fs.max_path_bytes]u8 = undefined;
    const target = try fs.readLinkAbsolute(link_path, &read_buf);

    var expected_buf: [fs.max_path_bytes]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "{s}/bin/mytool", .{keg_path});
    try std.testing.expectEqualStrings(expected, target);
}

test "link creates deep symlinks for lib files" {
    // Create fake prefix.
    var tmp_prefix = std.testing.tmpDir(.{});
    defer tmp_prefix.cleanup();

    // Create fake keg.
    var tmp_keg = std.testing.tmpDir(.{});
    defer tmp_keg.cleanup();

    // Create lib/pkgconfig/mytool.pc in keg.
    tmp_keg.dir.makePath("lib/pkgconfig") catch {};
    var f = try tmp_keg.dir.createFile("lib/pkgconfig/mytool.pc", .{});
    f.close();

    // Get real paths.
    var prefix_buf: [fs.max_path_bytes]u8 = undefined;
    const prefix_path = try tmp_prefix.dir.realpath(".", &prefix_buf);

    var keg_buf: [fs.max_path_bytes]u8 = undefined;
    const keg_path = try tmp_keg.dir.realpath(".", &keg_buf);

    const linker = Linker.init(std.testing.allocator, prefix_path);
    try linker.link("mytool", keg_path);

    // Verify {prefix}/lib/pkgconfig/mytool.pc is a symlink.
    var link_path_buf: [fs.max_path_bytes]u8 = undefined;
    const link_path = try std.fmt.bufPrint(&link_path_buf, "{s}/lib/pkgconfig/mytool.pc", .{prefix_path});

    var read_buf: [fs.max_path_bytes]u8 = undefined;
    const target = try fs.readLinkAbsolute(link_path, &read_buf);

    var expected_buf: [fs.max_path_bytes]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "{s}/lib/pkgconfig/mytool.pc", .{keg_path});
    try std.testing.expectEqualStrings(expected, target);
}

test "unlink removes symlinks" {
    // Create fake prefix with a bin/ directory containing a symlink.
    var tmp_prefix = std.testing.tmpDir(.{});
    defer tmp_prefix.cleanup();

    // Create fake keg directory.
    var tmp_keg = std.testing.tmpDir(.{});
    defer tmp_keg.cleanup();

    // Create a real file in keg.
    tmp_keg.dir.makeDir("bin") catch {};
    var f = try tmp_keg.dir.createFile("bin/hello", .{});
    f.close();

    // Get real paths.
    var prefix_buf: [fs.max_path_bytes]u8 = undefined;
    const prefix_path = try tmp_prefix.dir.realpath(".", &prefix_buf);

    var keg_buf: [fs.max_path_bytes]u8 = undefined;
    const keg_path = try tmp_keg.dir.realpath(".", &keg_buf);

    // First, link the keg contents.
    const linker = Linker.init(std.testing.allocator, prefix_path);
    try linker.link("hello", keg_path);

    // Verify the symlink exists.
    var link_path_buf: [fs.max_path_bytes]u8 = undefined;
    const link_path = try std.fmt.bufPrint(&link_path_buf, "{s}/bin/hello", .{prefix_path});

    var read_buf: [fs.max_path_bytes]u8 = undefined;
    _ = try fs.readLinkAbsolute(link_path, &read_buf);

    // Now unlink.
    try linker.unlink(keg_path);

    // Verify the symlink is gone.
    var verify_buf: [fs.max_path_bytes]u8 = undefined;
    _ = fs.readLinkAbsolute(link_path, &verify_buf) catch |err| {
        try std.testing.expect(err == error.FileNotFound);
        return;
    };

    // If we get here, the symlink still exists - that's a failure.
    return error.TestUnexpectedResult;
}

test "unlink removes opt link" {
    // Create a prefix with an opt link, then unlink and verify it's removed.
    var tmp_prefix = std.testing.tmpDir(.{});
    defer tmp_prefix.cleanup();

    var prefix_buf: [fs.max_path_bytes]u8 = undefined;
    const prefix_path = try tmp_prefix.dir.realpath(".", &prefix_buf);

    // Create an opt link manually.
    tmp_prefix.dir.makeDir("opt") catch {};
    const fake_keg = "/tmp/fakeCellar/hello/2.10";

    var opt_link_buf: [fs.max_path_bytes]u8 = undefined;
    const opt_link_path = try std.fmt.bufPrint(&opt_link_buf, "{s}/opt/hello", .{prefix_path});

    fs.symLinkAbsolute(fake_keg, opt_link_path, .{}) catch {};

    const linker = Linker.init(std.testing.allocator, prefix_path);
    try linker.unlink(fake_keg);

    // Verify opt link is gone.
    var verify_buf: [fs.max_path_bytes]u8 = undefined;
    _ = fs.readLinkAbsolute(opt_link_path, &verify_buf) catch |err| {
        try std.testing.expect(err == error.FileNotFound);
        return;
    };

    return error.TestUnexpectedResult;
}

test "parseKegName extracts name from keg path" {
    const name = parseKegName("/opt/homebrew/Cellar/hello/2.10");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("hello", name.?);

    const name2 = parseKegName("/usr/local/Cellar/openssl@3/3.1.0");
    try std.testing.expect(name2 != null);
    try std.testing.expectEqualStrings("openssl@3", name2.?);

    // Edge case: no slashes.
    try std.testing.expect(parseKegName("hello") == null);

    // Edge case: only one slash.
    try std.testing.expect(parseKegName("/hello") == null);
}
