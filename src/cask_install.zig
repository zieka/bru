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
const AppArtifact = cask.AppArtifact;

/// Default destination for app bundles. Matches Homebrew's default `appdir`.
const default_appdir: []const u8 = "/Applications";

/// Install a cask: download archive, extract, stage binaries, and link.
///
/// When `upgrade_from` is null this is a fresh install and fails if the cask
/// is already in the caskroom. When `upgrade_from` is a version string the
/// "already installed" guard is skipped; after the new version is linked the
/// old version's symlinks are unlinked and its caskroom directory is removed.
pub fn installCask(
    allocator: Allocator,
    config: Config,
    http_client: *HttpClient,
    resolved: ResolvedCask,
    upgrade_from: ?[]const u8,
) !void {
    const out = Output.init(config.no_color);
    const err_out = Output.initErr(config.no_color);

    // 1. Check if already installed (skip for upgrades).
    if (upgrade_from == null) {
        var caskroom_check_buf: [fs.max_path_bytes]u8 = undefined;
        const caskroom_check = std.fmt.bufPrint(&caskroom_check_buf, "{s}/{s}", .{ config.caskroom, resolved.token }) catch unreachable;
        if (fs.openDirAbsolute(caskroom_check, .{})) |dir| {
            var d = dir;
            d.close();
            out.warn("{s} is already installed.", .{resolved.token});
            return;
        } else |_| {}
    }

    // 2. Print section header.
    const action = if (upgrade_from != null) "Upgrading" else "Installing";
    const install_title = try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ action, resolved.name, resolved.version });
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

    // If we fail before linking, wipe the partial version_dir so it doesn't
    // masquerade as an installed version — cellar.installedVersions reads the
    // directory listing, so a stranded dir would falsely appear in `bru list`
    // and `bru outdated` (Bug 4).
    var commit = false;
    errdefer if (!commit) fs.deleteTreeAbsolute(version_dir) catch {};

    // 5. Determine archive type and extract.
    const archive_kind = try detectArchiveKind(resolved.url, archive_path);
    out.print("Extracting {s}...\n", .{resolved.token});

    switch (archive_kind) {
        .dmg => try extractDmg(allocator, archive_path, version_dir),
        .zip => try extractZip(allocator, archive_path, version_dir),
        .tar => try extractTar(allocator, archive_path, version_dir),
        .pkg => {
            err_out.warn("PKG archives cannot be extracted for binary-only install.", .{});
            err_out.print("Use: brew install --cask {s}\n", .{resolved.token});
            return error.UnsupportedArchiveType;
        },
        .unknown => {
            err_out.err("Unsupported archive format for {s}", .{resolved.token});
            return error.UnsupportedArchiveType;
        },
    }

    // 6. Stage app bundles into /Applications and leave a back-symlink in
    //    the Caskroom (matching brew's default behaviour). Apps go first so
    //    binaries living inside an .app bundle (e.g. docker-desktop's
    //    Docker.app/Contents/Resources/bin/docker) resolve against
    //    /Applications, not the to-be-emptied version_dir.
    //
    //    During upgrade, stageApp force-replaces the existing /Applications
    //    bundle (with a move-aside backup that's restored on failure). For a
    //    fresh install, AppAlreadyInstalled is fatal — silently continuing
    //    produced half-installed state where the caskroom and state file
    //    claimed the new version but the user's /Applications still held the
    //    old one (Bug 1).
    const is_upgrade = upgrade_from != null;
    for (resolved.apps) |app| {
        stageApp(allocator, version_dir, default_appdir, app, is_upgrade) catch |stage_err| switch (stage_err) {
            error.AppAlreadyInstalled => {
                err_out.err(
                    "{s} is already installed at {s}. Use `bru uninstall --cask {s}` first.",
                    .{ app.target, default_appdir, resolved.token },
                );
                return error.AppAlreadyInstalled;
            },
            else => {
                err_out.err(
                    "Could not stage app \"{s}\": {s}",
                    .{ app.target, @errorName(stage_err) },
                );
                return stage_err;
            },
        };
    }

    // 6b. Stage binary artifacts.
    if (resolved.binaries.len > 0) {
        const bin_dir = try std.fmt.allocPrint(allocator, "{s}/bin", .{version_dir});
        defer allocator.free(bin_dir);
        try fs.cwd().makePath(bin_dir);

        const source_roots = [_][]const u8{ version_dir, default_appdir };
        for (resolved.binaries) |binary| {
            stageBinary(allocator, &source_roots, bin_dir, binary) catch |stage_err| {
                err_out.warn("Could not stage binary \"{s}\": {s}", .{ binary.target, @errorName(stage_err) });
            };
        }
    }

    // 7. Link into prefix. For upgrades, first unlink the old version's
    //    symlinks so the new link can replace them cleanly.
    var linker = Linker.init(allocator, config.prefix);

    if (upgrade_from) |old_version| {
        if (!mem.eql(u8, old_version, resolved.version)) {
            const old_version_dir = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ config.caskroom, resolved.token, old_version });
            defer allocator.free(old_version_dir);
            linker.unlink(old_version_dir) catch |unlink_err| {
                err_out.warn("Failed to unlink old {s} {s}: {s}", .{ resolved.token, old_version, @errorName(unlink_err) });
            };
        }
    }

    try linker.link(resolved.token, version_dir);

    // New version is staged, linked, and visible. The install is committed —
    // any later failure (e.g. cleaning up the old version) is non-fatal and
    // must not roll back the new install.
    commit = true;

    // 8. For upgrades, remove the old caskroom version dir now that the new
    //    one is linked.
    if (upgrade_from) |old_version| {
        if (!mem.eql(u8, old_version, resolved.version)) {
            const old_version_dir = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ config.caskroom, resolved.token, old_version });
            defer allocator.free(old_version_dir);
            fs.deleteTreeAbsolute(old_version_dir) catch |del_err| {
                err_out.warn("Failed to remove old {s} {s}: {s}", .{ resolved.token, old_version, @errorName(del_err) });
            };
        }
    }

    // 9. Print completion.
    const done_verb = if (upgrade_from != null) "upgraded" else "installed";
    const done_title = try std.fmt.allocPrint(allocator, "{s} {s} is {s}", .{ resolved.name, resolved.version, done_verb });
    defer allocator.free(done_title);
    out.section(done_title);
}

const ArchiveKind = enum { dmg, zip, tar, pkg, unknown };

/// Decide how to extract a downloaded cask archive. Prefers the URL extension
/// (cheap, accurate for ~99% of casks) and falls back to sniffing the file's
/// magic bytes when the URL has no usable extension — e.g. VS Code's download
/// URL ends in `/darwin-arm64/stable` but the file is a zip. brew sniffs too.
fn detectArchiveKind(url: []const u8, archive_path: []const u8) !ArchiveKind {
    const ext = Download.urlExtension(url);
    if (mem.eql(u8, ext, ".dmg")) return .dmg;
    if (mem.eql(u8, ext, ".zip")) return .zip;
    if (mem.eql(u8, ext, ".tar.gz") or mem.eql(u8, ext, ".tar.bz2") or mem.eql(u8, ext, ".tar.xz")) return .tar;
    if (mem.eql(u8, ext, ".pkg")) return .pkg;
    return sniffArchiveKind(archive_path);
}

/// Read magic bytes from the head (and tail, for DMG) of a file to identify
/// the archive format. Returns .unknown when no signature matches.
fn sniffArchiveKind(archive_path: []const u8) !ArchiveKind {
    const file = try fs.cwd().openFile(archive_path, .{});
    defer file.close();

    // Read head magic.
    var head: [8]u8 = undefined;
    const head_len = try file.readAll(&head);

    if (head_len >= 4 and mem.eql(u8, head[0..4], "PK\x03\x04")) return .zip;
    if (head_len >= 4 and (mem.eql(u8, head[0..4], "PK\x05\x06") or mem.eql(u8, head[0..4], "PK\x07\x08"))) return .zip;
    if (head_len >= 2 and mem.eql(u8, head[0..2], "\x1f\x8b")) return .tar; // gzip — assume .tar.gz for casks
    if (head_len >= 3 and mem.eql(u8, head[0..3], "BZh")) return .tar;
    if (head_len >= 6 and mem.eql(u8, head[0..6], "\xfd7zXZ\x00")) return .tar;
    if (head_len >= 4 and mem.eql(u8, head[0..4], "xar!")) return .pkg;

    // DMG: UDIF "koly" trailer lives in the last 512 bytes at offset 0.
    const stat = try file.stat();
    if (stat.size >= 512) {
        try file.seekTo(stat.size - 512);
        var trailer: [4]u8 = undefined;
        if ((try file.readAll(&trailer)) == 4 and mem.eql(u8, &trailer, "koly")) {
            return .dmg;
        }
    }

    return .unknown;
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

/// Stage a single app-bundle artifact:
///   1. Verify the extracted source bundle exists.
///   2. If the destination already exists and `is_upgrade` is false, return
///      `error.AppAlreadyInstalled` so the caller aborts the install — never
///      silently proceed (that produced half-installed state, see Bug 1).
///   3. If `is_upgrade` is true and the destination exists, move it aside to a
///      sibling backup path before staging, restoring it if the move fails.
///   4. Move new bundle from `{version_dir}/{app.source}` to `{appdir}/{app.target}`
///      using rename (same-volume) or `ditto`+`rm -rf` (cross-volume fallback).
///   5. Leave a back-symlink at `{version_dir}/{app.target}` pointing to the
///      installed bundle — matches brew's Caskroom layout.
///   6. On full success, delete the moved-aside backup.
fn stageApp(allocator: Allocator, version_dir: []const u8, appdir: []const u8, app: AppArtifact, is_upgrade: bool) !void {
    const source_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ version_dir, app.source });
    defer allocator.free(source_path);

    const target_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ appdir, app.target });
    defer allocator.free(target_path);

    fs.cwd().access(source_path, .{}) catch {
        return error.AppNotFound;
    };

    const target_exists = blk: {
        fs.cwd().access(target_path, .{}) catch break :blk false;
        break :blk true;
    };

    if (target_exists and !is_upgrade) {
        return error.AppAlreadyInstalled;
    }

    // For upgrade-with-existing-target: move target aside to a sibling backup
    // path. If staging fails we restore it; if it succeeds we delete it.
    var backup_path_opt: ?[]u8 = null;
    defer if (backup_path_opt) |p| allocator.free(p);

    if (target_exists) {
        const backup_path = try std.fmt.allocPrint(allocator, "{s}.bru-replacing.{d}", .{ target_path, std.time.nanoTimestamp() });
        backup_path_opt = backup_path;
        try fs.renameAbsolute(target_path, backup_path);
    }

    // Try to move the new bundle into place. On failure, restore the backup.
    moveAppIntoPlace(allocator, source_path, target_path) catch |err| {
        if (backup_path_opt) |p| {
            fs.renameAbsolute(p, target_path) catch {};
        }
        return err;
    };

    // Back-symlink {version_dir}/{target} -> {appdir}/{target}.
    const back_link = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ version_dir, app.target });
    defer allocator.free(back_link);
    fs.deleteFileAbsolute(back_link) catch |err| switch (err) {
        error.FileNotFound, error.IsDir => {},
        else => return err,
    };
    try fs.symLinkAbsolute(target_path, back_link, .{});

    // Success — drop the backup. Best-effort; a leftover .bru-replacing dir is
    // harmless and is overwritten on the next upgrade attempt.
    if (backup_path_opt) |p| {
        fs.deleteTreeAbsolute(p) catch {};
    }
}

/// Same-volume rename, falling back to `ditto`+`rm -rf` across volumes so
/// extended attributes (quarantine flags, ACLs) survive.
fn moveAppIntoPlace(allocator: Allocator, source_path: []const u8, target_path: []const u8) !void {
    if (fs.renameAbsolute(source_path, target_path)) |_| {
        return;
    } else |rename_err| switch (rename_err) {
        error.RenameAcrossMountPoints => try copyAppCrossVolume(allocator, source_path, target_path),
        else => return rename_err,
    }
}

/// Recursively copy an .app bundle across volumes using `ditto`, then remove
/// the source. `ditto` preserves resource forks, ACLs, and extended attrs —
/// `cp -R` does not, so don't substitute it.
fn copyAppCrossVolume(allocator: Allocator, src: []const u8, dst: []const u8) !void {
    const ditto = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "ditto", src, dst },
    });
    defer allocator.free(ditto.stdout);
    defer allocator.free(ditto.stderr);
    switch (ditto.term) {
        .Exited => |code| if (code != 0) return error.AppCopyFailed,
        else => return error.AppCopyFailed,
    }
    const rm = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "rm", "-rf", src },
    });
    defer allocator.free(rm.stdout);
    defer allocator.free(rm.stderr);
}

/// Stage a single binary artifact: find it under one of the source roots and
/// symlink it into the cask's bin/ directory.
///
/// `source_roots` are tried in order — typically `[version_dir, /Applications]`
/// — because a binary may live in the extracted tree (most casks) or inside
/// an .app bundle that was already moved to /Applications (e.g. docker).
///
/// `binary.target` may be an absolute path in the cask DSL (e.g.
/// `/usr/local/bin/docker`). bru's Linker always symlinks
/// `{prefix}/bin/{basename}` → `{bin_dir}/{basename}`, so the basename is
/// what actually matters; ignore everything else.
fn stageBinary(allocator: Allocator, source_roots: []const []const u8, bin_dir: []const u8, binary: BinaryArtifact) !void {
    // Resolve the source by probing each root in order.
    const source_path = try resolveBinarySource(allocator, source_roots, binary.source);
    defer allocator.free(source_path);

    // Normalize target to a basename — brew DSL allows absolute paths but
    // bru stages to {bin_dir}/{basename} regardless.
    const target_name = std.fs.path.basename(binary.target);
    const target_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ bin_dir, target_name });
    defer allocator.free(target_path);

    // Ensure the source is executable.
    const source_file = try fs.cwd().openFile(source_path, .{});
    defer source_file.close();
    const stat = try source_file.stat();

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

    try fs.symLinkAbsolute(source_path, target_path, .{});
}

/// Probe each `source_roots` entry for `binary.source`, returning the first
/// path that exists. Returns error.BinaryNotFound if none match.
/// Caller owns the returned string.
fn resolveBinarySource(allocator: Allocator, source_roots: []const []const u8, binary_source: []const u8) ![]u8 {
    for (source_roots) |root| {
        const candidate = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, binary_source });
        if (fs.cwd().access(candidate, .{})) |_| {
            return candidate;
        } else |_| {
            allocator.free(candidate);
        }
    }
    return error.BinaryNotFound;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "detectArchiveKind prefers known URL extensions" {
    // Mock archive_path won't be read when ext matches a known type.
    try std.testing.expectEqual(ArchiveKind.zip, try detectArchiveKind("https://example.com/app.zip", "/nonexistent"));
    try std.testing.expectEqual(ArchiveKind.dmg, try detectArchiveKind("https://example.com/app.dmg", "/nonexistent"));
    try std.testing.expectEqual(ArchiveKind.tar, try detectArchiveKind("https://example.com/app.tar.gz", "/nonexistent"));
    try std.testing.expectEqual(ArchiveKind.pkg, try detectArchiveKind("https://example.com/app.pkg", "/nonexistent"));
}

test "sniffArchiveKind detects zip by magic bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("payload", .{});
    try f.writeAll("PK\x03\x04\x14\x00\x00\x00");
    f.close();

    var buf: [fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath("payload", &buf);

    try std.testing.expectEqual(ArchiveKind.zip, try sniffArchiveKind(path));
}

test "sniffArchiveKind detects gzip as tar" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("payload", .{});
    try f.writeAll("\x1f\x8b\x08\x00");
    f.close();

    var buf: [fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath("payload", &buf);

    try std.testing.expectEqual(ArchiveKind.tar, try sniffArchiveKind(path));
}

test "sniffArchiveKind returns unknown for unrecognized data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile("payload", .{});
    try f.writeAll("hello world this is not an archive");
    f.close();

    var buf: [fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath("payload", &buf);

    try std.testing.expectEqual(ArchiveKind.unknown, try sniffArchiveKind(path));
}

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
    const roots = [_][]const u8{version_dir};
    try stageBinary(allocator, &roots, bin_dir, binary);

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
    const roots = [_][]const u8{version_dir};
    const result = stageBinary(allocator, &roots, bin_dir, binary);
    try std.testing.expectError(error.BinaryNotFound, result);
}

// ---------------------------------------------------------------------------
// Bug 1: silent-skip on AppAlreadyInstalled
// Upgrade must replace the existing .app; fresh install must abort cleanly.
// ---------------------------------------------------------------------------

test "stageApp returns AppAlreadyInstalled when fresh install and target exists" {
    const allocator = std.testing.allocator;

    var version_tmp = std.testing.tmpDir(.{});
    defer version_tmp.cleanup();
    var apps_tmp = std.testing.tmpDir(.{});
    defer apps_tmp.cleanup();

    // New version on disk in version_dir.
    try version_tmp.dir.makePath("Foo.app");
    const new_marker = try version_tmp.dir.createFile("Foo.app/marker", .{});
    try new_marker.writeAll("new");
    new_marker.close();

    // Old version already at appdir — must not be replaced for fresh install.
    try apps_tmp.dir.makePath("Foo.app");
    const old_marker = try apps_tmp.dir.createFile("Foo.app/marker", .{});
    try old_marker.writeAll("old");
    old_marker.close();

    var v_buf: [fs.max_path_bytes]u8 = undefined;
    const version_dir = try version_tmp.dir.realpath(".", &v_buf);
    var a_buf: [fs.max_path_bytes]u8 = undefined;
    const apps_dir = try apps_tmp.dir.realpath(".", &a_buf);

    const app = AppArtifact{ .source = "Foo.app", .target = "Foo.app" };
    const result = stageApp(allocator, version_dir, apps_dir, app, false);
    try std.testing.expectError(error.AppAlreadyInstalled, result);

    // Old content must survive.
    const f = try apps_tmp.dir.openFile("Foo.app/marker", .{});
    defer f.close();
    var read: [3]u8 = undefined;
    _ = try f.readAll(&read);
    try std.testing.expectEqualStrings("old", &read);
}

test "stageApp replaces existing target when upgrading" {
    const allocator = std.testing.allocator;

    var version_tmp = std.testing.tmpDir(.{});
    defer version_tmp.cleanup();
    var apps_tmp = std.testing.tmpDir(.{});
    defer apps_tmp.cleanup();

    try version_tmp.dir.makePath("Foo.app");
    const new_marker = try version_tmp.dir.createFile("Foo.app/marker", .{});
    try new_marker.writeAll("new");
    new_marker.close();

    try apps_tmp.dir.makePath("Foo.app");
    const old_marker = try apps_tmp.dir.createFile("Foo.app/marker", .{});
    try old_marker.writeAll("old");
    old_marker.close();

    var v_buf: [fs.max_path_bytes]u8 = undefined;
    const version_dir = try version_tmp.dir.realpath(".", &v_buf);
    var a_buf: [fs.max_path_bytes]u8 = undefined;
    const apps_dir = try apps_tmp.dir.realpath(".", &a_buf);

    const app = AppArtifact{ .source = "Foo.app", .target = "Foo.app" };
    try stageApp(allocator, version_dir, apps_dir, app, true);

    // /Applications/Foo.app/marker should now contain "new".
    const f = try apps_tmp.dir.openFile("Foo.app/marker", .{});
    defer f.close();
    var read: [3]u8 = undefined;
    _ = try f.readAll(&read);
    try std.testing.expectEqualStrings("new", &read);

    // No leftover .bru-replacing-* directories.
    var apps_iter = try apps_tmp.dir.openDir(".", .{ .iterate = true });
    defer apps_iter.close();
    var walker = apps_iter.iterate();
    while (try walker.next()) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, entry.name, ".bru-replacing") == null);
    }
}

test "stageApp upgrade with no existing target installs cleanly" {
    const allocator = std.testing.allocator;

    var version_tmp = std.testing.tmpDir(.{});
    defer version_tmp.cleanup();
    var apps_tmp = std.testing.tmpDir(.{});
    defer apps_tmp.cleanup();

    try version_tmp.dir.makePath("Bar.app");
    const f = try version_tmp.dir.createFile("Bar.app/marker", .{});
    try f.writeAll("v2");
    f.close();

    var v_buf: [fs.max_path_bytes]u8 = undefined;
    const version_dir = try version_tmp.dir.realpath(".", &v_buf);
    var a_buf: [fs.max_path_bytes]u8 = undefined;
    const apps_dir = try apps_tmp.dir.realpath(".", &a_buf);

    const app = AppArtifact{ .source = "Bar.app", .target = "Bar.app" };
    try stageApp(allocator, version_dir, apps_dir, app, true);

    const f2 = try apps_tmp.dir.openFile("Bar.app/marker", .{});
    defer f2.close();
    var read: [2]u8 = undefined;
    _ = try f2.readAll(&read);
    try std.testing.expectEqualStrings("v2", &read);
}

test "stageBinary falls back to second source root" {
    const allocator = std.testing.allocator;

    // Mimic the docker-desktop layout: the .app moved out of version_dir
    // and now lives at the second root (a stand-in for /Applications).
    var version_tmp = std.testing.tmpDir(.{});
    defer version_tmp.cleanup();
    var apps_tmp = std.testing.tmpDir(.{});
    defer apps_tmp.cleanup();

    try apps_tmp.dir.makePath("Docker.app/Contents/Resources/bin");
    const f = try apps_tmp.dir.createFile("Docker.app/Contents/Resources/bin/docker", .{});
    try f.writeAll("#!/bin/sh\n");
    f.close();

    try version_tmp.dir.makeDir("bin");

    var version_buf: [fs.max_path_bytes]u8 = undefined;
    const version_dir = try version_tmp.dir.realpath(".", &version_buf);
    var apps_buf: [fs.max_path_bytes]u8 = undefined;
    const apps_dir = try apps_tmp.dir.realpath(".", &apps_buf);
    var bin_buf: [fs.max_path_bytes]u8 = undefined;
    const bin_dir = try version_tmp.dir.realpath("bin", &bin_buf);

    const binary = BinaryArtifact{
        .source = "Docker.app/Contents/Resources/bin/docker",
        .target = "/usr/local/bin/docker", // absolute — should normalize to basename.
    };
    const roots = [_][]const u8{ version_dir, apps_dir };
    try stageBinary(allocator, &roots, bin_dir, binary);

    // Symlink should land at {bin_dir}/docker (basename of the absolute target).
    var link_buf: [fs.max_path_bytes]u8 = undefined;
    const link_path = try std.fmt.bufPrint(&link_buf, "{s}/docker", .{bin_dir});
    var read_buf: [fs.max_path_bytes]u8 = undefined;
    const target = try fs.readLinkAbsolute(link_path, &read_buf);

    var expected_buf: [fs.max_path_bytes]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "{s}/Docker.app/Contents/Resources/bin/docker", .{apps_dir});
    try std.testing.expectEqualStrings(expected, target);
}
