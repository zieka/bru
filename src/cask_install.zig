const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;
const Config = @import("config.zig").Config;
const HttpClient = @import("http.zig").HttpClient;
const Download = @import("download.zig").Download;
const Linker = @import("linker.zig").Linker;
const Output = @import("output.zig").Output;
const cask = @import("cask.zig");
const ResolvedCask = cask.ResolvedCask;
const BinaryArtifact = cask.BinaryArtifact;

/// Install a cask: download archive, extract, stage binaries, and link.
pub fn installCask(allocator: Allocator, config: Config, http_client: *HttpClient, resolved: ResolvedCask) !void {
    const out = Output.init(config.no_color);
    const err_out = Output.initErr(config.no_color);

    // 1. Check if already installed.
    var caskroom_check_buf: [fs.max_path_bytes]u8 = undefined;
    const caskroom_check = std.fmt.bufPrint(&caskroom_check_buf, "{s}/{s}", .{ config.caskroom, resolved.token }) catch unreachable;
    if (fs.openDirAbsolute(caskroom_check, .{})) |dir| {
        var d = dir;
        d.close();
        out.warn("{s} is already installed.", .{resolved.token});
        return;
    } else |_| {}

    // 2. Print section header.
    const install_title = try std.fmt.allocPrint(allocator, "Installing {s} {s}", .{ resolved.name, resolved.version });
    defer allocator.free(install_title);
    out.section(install_title);

    // 3. Download archive.
    out.print("Downloading {s}...\n", .{resolved.token});
    var dl = Download.init(allocator, config.cache, http_client);
    const archive_path = try dl.fetchCask(resolved.url, resolved.sha256);
    defer allocator.free(archive_path);

    // 4. Create caskroom directory: {caskroom}/{token}/{version}/
    const version_dir = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ config.caskroom, resolved.token, resolved.version });
    defer allocator.free(version_dir);
    try fs.cwd().makePath(version_dir);

    // 5. Determine archive type and extract.
    const ext = Download.urlExtension(resolved.url);
    out.print("Extracting {s}...\n", .{resolved.token});

    if (mem.eql(u8, ext, ".dmg")) {
        try extractDmg(allocator, archive_path, version_dir);
    } else if (mem.eql(u8, ext, ".zip")) {
        try extractZip(allocator, archive_path, version_dir);
    } else if (mem.eql(u8, ext, ".tar.gz") or mem.eql(u8, ext, ".tar.bz2") or mem.eql(u8, ext, ".tar.xz")) {
        try extractTar(allocator, archive_path, version_dir);
    } else if (mem.eql(u8, ext, ".pkg")) {
        err_out.warn("PKG archives cannot be extracted for binary-only install.", .{});
        err_out.print("Use: brew install --cask {s}\n", .{resolved.token});
        return error.UnsupportedArchiveType;
    } else {
        err_out.err("Unsupported archive format: {s}", .{ext});
        return error.UnsupportedArchiveType;
    }

    // 6. Stage binary artifacts.
    if (resolved.binaries.len > 0) {
        const bin_dir = try std.fmt.allocPrint(allocator, "{s}/bin", .{version_dir});
        defer allocator.free(bin_dir);
        try fs.cwd().makePath(bin_dir);

        for (resolved.binaries) |binary| {
            stageBinary(allocator, version_dir, bin_dir, binary) catch |stage_err| {
                err_out.warn("Could not stage binary \"{s}\": {s}", .{ binary.target, @errorName(stage_err) });
            };
        }
    }

    // 7. Link into prefix.
    var linker = Linker.init(allocator, config.prefix);
    try linker.link(resolved.token, version_dir);

    // 8. Print completion.
    const done_title = try std.fmt.allocPrint(allocator, "{s} {s} is installed", .{ resolved.name, resolved.version });
    defer allocator.free(done_title);
    out.section(done_title);
}

/// Extract a DMG archive by mounting it, copying contents, and unmounting.
fn extractDmg(allocator: Allocator, dmg_path: []const u8, dest_dir: []const u8) !void {
    // Create a temporary mount point.
    const mount_point = try std.fmt.allocPrint(allocator, "/tmp/bru-dmg-{d}", .{std.time.nanoTimestamp()});
    defer allocator.free(mount_point);
    try fs.cwd().makePath(mount_point);
    defer fs.cwd().deleteDir(mount_point) catch {};

    // Mount the DMG.
    {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", mount_point, dmg_path },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        switch (result.term) {
            .Exited => |code| if (code != 0) return error.DmgMountFailed,
            else => return error.DmgMountFailed,
        }
    }

    // Ensure we detach on exit.
    defer detachDmg(allocator, mount_point);

    // Copy contents from mount point to dest_dir using ditto (preserves metadata).
    const src_slash = try std.fmt.allocPrint(allocator, "{s}/.", .{mount_point});
    defer allocator.free(src_slash);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "ditto", src_slash, dest_dir },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code != 0) return error.DmgCopyFailed,
        else => return error.DmgCopyFailed,
    }
}

/// Detach a DMG mount point, ignoring errors.
fn detachDmg(allocator: Allocator, mount_point: []const u8) void {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "hdiutil", "detach", mount_point, "-force" },
    }) catch return;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

/// Extract a ZIP archive using unzip.
fn extractZip(allocator: Allocator, zip_path: []const u8, dest_dir: []const u8) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "unzip", "-o", "-q", zip_path, "-d", dest_dir },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code != 0) return error.UnzipFailed,
        else => return error.UnzipFailed,
    }
}

/// Extract a tar archive (tar.gz, tar.bz2, tar.xz) using tar.
fn extractTar(allocator: Allocator, tar_path: []const u8, dest_dir: []const u8) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "tar", "xf", tar_path, "-C", dest_dir },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code != 0) return error.TarFailed,
        else => return error.TarFailed,
    }
}

/// Stage a single binary artifact: find it in the extracted tree and
/// symlink it into the cask's bin/ directory.
fn stageBinary(allocator: Allocator, version_dir: []const u8, bin_dir: []const u8, binary: BinaryArtifact) !void {
    // Build the full source path within the extracted tree.
    const source_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ version_dir, binary.source });
    defer allocator.free(source_path);

    // Build the target path in bin/.
    const target_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ bin_dir, binary.target });
    defer allocator.free(target_path);

    // Verify the source exists.
    fs.cwd().access(source_path, .{}) catch {
        return error.BinaryNotFound;
    };

    // Ensure the source is executable.
    const source_file = try fs.cwd().openFile(source_path, .{});
    defer source_file.close();
    const stat = try source_file.stat();

    // Add execute permissions if not already set.
    const mode = stat.mode;
    const new_mode = mode | 0o111;
    if (new_mode != mode) {
        try source_file.chmod(new_mode);
    }

    // Remove existing symlink/file at target.
    fs.deleteFileAbsolute(target_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    // Create symlink: bin/{target} -> {version_dir}/{source}
    try fs.symLinkAbsolute(source_path, target_path, .{});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "cask_install compiles" {
    // Verify this module compiles and links correctly.
    _ = installCask;
    _ = extractZip;
    _ = extractTar;
}

test "stageBinary creates symlink and sets executable" {
    const allocator = std.testing.allocator;

    // Create fake version directory with a binary.
    var tmp_version = std.testing.tmpDir(.{});
    defer tmp_version.cleanup();

    // Create a fake binary file.
    const f = try tmp_version.dir.createFile("my-tool.sh", .{});
    try f.writeAll("#!/bin/sh\necho hello\n");
    f.close();

    // Create bin/ directory.
    try tmp_version.dir.makeDir("bin");

    // Get real paths.
    var version_buf: [fs.max_path_bytes]u8 = undefined;
    const version_dir = try tmp_version.dir.realpath(".", &version_buf);

    var bin_buf: [fs.max_path_bytes]u8 = undefined;
    const bin_dir = try tmp_version.dir.realpath("bin", &bin_buf);

    const binary = BinaryArtifact{ .source = "my-tool.sh", .target = "mytool" };
    try stageBinary(allocator, version_dir, bin_dir, binary);

    // Verify the symlink exists and points to the source.
    var link_path_buf: [fs.max_path_bytes]u8 = undefined;
    const link_path = try std.fmt.bufPrint(&link_path_buf, "{s}/mytool", .{bin_dir});

    var read_buf: [fs.max_path_bytes]u8 = undefined;
    const target = try fs.readLinkAbsolute(link_path, &read_buf);

    var expected_buf: [fs.max_path_bytes]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "{s}/my-tool.sh", .{version_dir});
    try std.testing.expectEqualStrings(expected, target);

    // Verify the source is executable.
    const stat = try tmp_version.dir.statFile("my-tool.sh");
    try std.testing.expect((stat.mode & 0o111) != 0);
}

test "stageBinary returns error for missing binary" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("bin");

    var version_buf: [fs.max_path_bytes]u8 = undefined;
    const version_dir = try tmp.dir.realpath(".", &version_buf);

    var bin_buf: [fs.max_path_bytes]u8 = undefined;
    const bin_dir = try tmp.dir.realpath("bin", &bin_buf);

    const binary = BinaryArtifact{ .source = "nonexistent", .target = "mytool" };
    const result = stageBinary(allocator, version_dir, bin_dir, binary);
    try std.testing.expectError(error.BinaryNotFound, result);
}
