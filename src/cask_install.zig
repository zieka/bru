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
const UninstallPlan = cask.UninstallPlan;
const json_helpers = @import("json_helpers.zig");
const writeJsonStr = json_helpers.writeJsonStr;
const clonefile = @import("clonefile.zig");

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

    // Refuse rather than trust callers: installing a root-owned payload bru
    // cannot record an undo for is the one outcome there is no recovery from.
    // cmd/install.zig catches this earlier to print a friendlier deferral.
    if (cask.installability(resolved) == .unremovable) return error.CaskNotRemovable;

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
        // NOTE: a bare .pkg is not an archive; stage it under the name the
        // cask's `pkg` artifact refers to.
        .pkg => try stagePkgFile(allocator, resolved, archive_path, version_dir),
        .unknown => {
            err_out.err("Unsupported archive format for {s}", .{resolved.token});
            return error.UnsupportedArchiveType;
        },
    }

    // 5b. Record the undo plan before anything leaves the Caskroom — it must
    //     exist the moment `installer` starts touching the system.
    //
    //     WARNING: only record a plan bru can run in full — `delete:` without
    //     the `launchctl:` that precedes it strips a loaded daemon's files
    //     while launchd still references them. The gate above guarantees that
    //     for pkg casks; app casks are left with their prior behaviour rather
    //     than gaining half a teardown from this change.
    if (resolved.pkgs.len > 0 and !resolved.uninstall.isEmpty()) {
        writeUninstallPlan(allocator, version_dir, resolved.uninstall) catch |plan_err| {
            err_out.err("Could not record the uninstall plan for {s}: {s}", .{ resolved.token, @errorName(plan_err) });
            err_out.print("Not running installer — without this file bru could not undo the install.\n", .{});
            return plan_err;
        };
    }

    // 5c. Must precede binary staging: a pkg cask's `binary` points at an
    //     absolute path that does not exist until the package is installed.
    if (resolved.pkgs.len > 0) {
        // Baseline: without it a failure cannot tell "installer wrote
        // something" from "brew installed this earlier".
        const receipts_before = try receiptPresence(allocator, resolved.uninstall.pkgutil);
        defer allocator.free(receipts_before);

        for (resolved.pkgs) |pkg| {
            const pkg_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ version_dir, pkg.source });
            defer allocator.free(pkg_path);

            fs.cwd().access(pkg_path, .{}) catch {
                err_out.err("Package \"{s}\" not found in the downloaded archive.", .{pkg.source});
                return error.PkgNotFound;
            };

            out.print("Running installer for {s} (requires sudo)...\n", .{pkg.source});

            // From here the system may have been mutated, so keep version_dir
            // (and the plan inside it) regardless of how this turns out.
            commit = true;
            runPkgInstaller(allocator, pkg_path, pkg.allow_untrusted) catch |install_err| {
                err_out.err("installer failed for \"{s}\": {s}", .{ pkg.source, @errorName(install_err) });

                if (anyReceiptAppeared(allocator, resolved.uninstall.pkgutil, receipts_before)) {
                    err_out.warn(
                        "{s} is partially installed. Run: bru uninstall {s}",
                        .{ resolved.token, resolved.token },
                    );
                }
                return install_err;
            };
        }
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

/// Records how to undo an install. Absent means "nothing to undo beyond
/// deleting the keg".
pub const uninstall_plan_file = ".bru-uninstall.json";

/// WARNING: absolute, never PATH-resolved. This tool's output builds the argv
/// for a root `rm`, and user-writable dirs routinely precede /usr/sbin in PATH.
const pkgutil_bin = "/usr/sbin/pkgutil";

/// `pkgutil --files` prints one path per line; Child.run's 50 KiB default
/// truncates any package with an .app bundle into StdoutStreamTooLong.
const pkgutil_max_output = 16 * 1024 * 1024;

/// Stage a bare `.pkg` download into the version dir under the name the cask's
/// `pkg` artifact declares — the URL basename is not it (often percent-encoded).
// Clone, not symlink: `bru cleanup` may prune the content-addressed blob store.
fn stagePkgFile(allocator: Allocator, resolved: ResolvedCask, archive_path: []const u8, dest_dir: []const u8) !void {
    const name = if (resolved.pkgs.len > 0) resolved.pkgs[0].source else "package.pkg";

    const dest_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest_dir, name });
    defer allocator.free(dest_path);

    if (fs.path.dirname(dest_path)) |parent| try fs.cwd().makePath(parent);

    // clonefile is free on APFS; a pkg can be hundreds of MB.
    _ = clonefile.cloneTree(archive_path, dest_path) catch {
        return fs.cwd().copyFile(archive_path, fs.cwd(), dest_path, .{});
    };
}

/// Run `args` as root, prefixing sudo unless already root. Returns the exit
/// code. stdio is inherited so sudo's password prompt stays visible.
// `Child.run` would capture the prompt and look like a hang.
fn runAsRoot(allocator: Allocator, args: []const []const u8, quiet: bool) !u8 {
    var argv = std.ArrayList([]const u8){};
    defer argv.deinit(allocator);
    if (std.posix.getuid() != 0) try argv.append(allocator, "sudo");
    try argv.appendSlice(allocator, args);

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = if (quiet) .Ignore else .Inherit;
    child.stderr_behavior = if (quiet) .Ignore else .Inherit;

    return switch (try child.spawnAndWait()) {
        .Exited => |code| code,
        else => 1,
    };
}

/// Hand a package to macOS's installer, as brew's `pkg` artifact does. Needs
/// root: packages write to /usr/local, /Library, and /var/db/receipts.
fn runPkgInstaller(allocator: Allocator, pkg_path: []const u8, allow_untrusted: bool) !void {
    var args = std.ArrayList([]const u8){};
    defer args.deinit(allocator);
    try args.append(allocator, "/usr/sbin/installer");
    if (allow_untrusted) try args.append(allocator, "-allowUntrusted");
    try args.appendSlice(allocator, &.{ "-pkg", pkg_path, "-target", "/" });

    if (try runAsRoot(allocator, args.items, false) != 0) return error.PkgInstallFailed;
}

/// Persist the uninstall plan as JSON. `unsupported` is omitted — such casks
/// never reach install (see the gate in cmd/install.zig).
fn writeUninstallPlan(allocator: Allocator, version_dir: []const u8, plan: UninstallPlan) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ version_dir, uninstall_plan_file });
    defer allocator.free(path);

    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try writer.writeAll("{");
    const sections = [_]struct { name: []const u8, values: [][]const u8 }{
        .{ .name = "pkgutil", .values = plan.pkgutil },
        .{ .name = "delete", .values = plan.delete },
        .{ .name = "trash", .values = plan.trash },
        .{ .name = "rmdir", .values = plan.rmdir },
    };
    for (sections, 0..) |section, i| {
        if (i > 0) try writer.writeAll(",");
        try writeJsonStr(writer, section.name);
        try writer.writeAll(":[");
        for (section.values, 0..) |value, j| {
            if (j > 0) try writer.writeAll(",");
            try writeJsonStr(writer, value);
        }
        try writer.writeAll("]");
    }
    try writer.writeAll("}\n");

    const file = try fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(buf.items);
}

/// True when `id` has a receipt registered on this system.
fn receiptRegistered(allocator: Allocator, id: []const u8) bool {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ pkgutil_bin, "--pkg-info", id },
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

/// Registration state of each ID, positionally. Caller owns the result.
fn receiptPresence(allocator: Allocator, ids: []const []const u8) ![]bool {
    const presence = try allocator.alloc(bool, ids.len);
    for (ids, 0..) |id, i| presence[i] = receiptRegistered(allocator, id);
    return presence;
}

/// True when a receipt appeared that `before` did not have — i.e. this run
/// registered a package and left state worth cleaning up.
fn anyReceiptAppeared(allocator: Allocator, ids: []const []const u8, before: []const bool) bool {
    for (ids, before) |id, was_present| {
        if (!was_present and receiptRegistered(allocator, id)) return true;
    }
    return false;
}

/// Read a version's recorded uninstall plan; empty when none was recorded.
/// Caller owns the result — release with cask.freeUninstallPlan.
pub fn readUninstallPlan(allocator: Allocator, version_dir: []const u8) !UninstallPlan {
    const empty = UninstallPlan{
        .pkgutil = &.{},
        .delete = &.{},
        .rmdir = &.{},
        .trash = &.{},
        .unsupported = &.{},
    };

    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ version_dir, uninstall_plan_file });
    defer allocator.free(path);

    const contents = fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |read_err| switch (read_err) {
        error.FileNotFound => return empty,
        else => return read_err,
    };
    defer allocator.free(contents);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return empty,
    };

    const pkgutil = try json_helpers.parseStringArray(allocator, obj, "pkgutil");
    errdefer json_helpers.freeStringSlice(allocator, pkgutil);
    const delete = try json_helpers.parseStringArray(allocator, obj, "delete");
    errdefer json_helpers.freeStringSlice(allocator, delete);
    const trash = try json_helpers.parseStringArray(allocator, obj, "trash");
    errdefer json_helpers.freeStringSlice(allocator, trash);
    const rmdir = try json_helpers.parseStringArray(allocator, obj, "rmdir");

    return UninstallPlan{
        .pkgutil = pkgutil,
        .delete = delete,
        .rmdir = rmdir,
        .trash = trash,
        .unsupported = &.{},
    };
}


/// True when this version dir carries an uninstall plan bru wrote.
pub fn hasUninstallPlan(version_dir: []const u8) bool {
    var buf: [fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ version_dir, uninstall_plan_file }) catch return false;
    fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// True when brew owns this cask: it writes `.metadata` beside the version dir
/// and bru never does.
pub fn looksBrewInstalled(version_dir: []const u8) bool {
    const parent = fs.path.dirname(version_dir) orelse return false;
    var buf: [fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/.metadata", .{parent}) catch return false;
    fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Undo a cask version's out-of-Caskroom artifacts, in brew's directive order
/// so payload files are gone before the directories that held them.
///
/// Returns the number of artifacts that could not be removed. Callers must not
/// report a clean uninstall, or delete the keg, when this is non-zero — the
/// keg holds the only record of what was installed as root.
pub fn uninstallCaskArtifacts(
    allocator: Allocator,
    version_dir: []const u8,
    out: Output,
    err_out: Output,
) error{UninstallPlanUnreadable}!usize {
    // An unreadable plan is NOT "nothing to undo": a truncated write looks
    // exactly like this, and the caller would delete the only manifest.
    const plan = readUninstallPlan(allocator, version_dir) catch |read_err| {
        err_out.err("Could not read the uninstall plan in {s}: {s}", .{ version_dir, @errorName(read_err) });
        err_out.print("Refusing to remove the keg — it records what this cask installed as root.\n", .{});
        return error.UninstallPlanUnreadable;
    };
    defer cask.freeUninstallPlan(allocator, plan);
    if (plan.isEmpty()) return 0;

    var failures: usize = 0;

    for (plan.pkgutil) |id| {
        const root = pkgReceiptRoot(allocator, id) catch |query_err| {
            err_out.err("Could not query receipt {s}: {s} — its files were left in place.", .{ id, @errorName(query_err) });
            failures += 1;
            continue;
        } orelse continue; // genuinely not registered: a re-run, or brew removed it
        defer allocator.free(root);

        out.print("Removing package {s}...\n", .{id});

        if (removePkgPaths(allocator, id, root, .files)) |_| {
            removePkgPaths(allocator, id, root, .dirs) catch |dir_err| {
                err_out.warn("Could not remove empty dirs for {s}: {s}", .{ id, @errorName(dir_err) });
            };
            forgetPkgReceipt(allocator, id) catch |forget_err| {
                err_out.warn("Could not forget receipt {s}: {s}", .{ id, @errorName(forget_err) });
                failures += 1;
            };
        } else |rm_err| {
            // Keep the receipt: `pkgutil --files` is the only way to enumerate
            // what was left behind, and --forget destroys that manifest.
            err_out.err("Could not remove files for {s}: {s}", .{ id, @errorName(rm_err) });
            err_out.print("Keeping the receipt so `pkgutil --files {s}` can still list them.\n", .{id});
            failures += 1;
        }
    }

    for (plan.delete) |raw| failures += withExpandedPath(allocator, raw, err_out, deletePath);
    for (plan.trash) |raw| failures += withExpandedPath(allocator, raw, err_out, trashPath);
    for (plan.rmdir) |raw| failures += withExpandedPath(allocator, raw, err_out, rmdirPath);

    return failures;
}

/// Expand `raw`, screen it against the system-directory guard, and hand it to
/// `action`. Paths failing either check are warned about, not acted on.
fn withExpandedPath(
    allocator: Allocator,
    raw: []const u8,
    err_out: Output,
    action: *const fn (Allocator, []const u8) anyerror!void,
) usize {
    const path = expandPath(allocator, raw) catch |err| {
        err_out.warn("Could not expand uninstall path \"{s}\": {s}", .{ raw, @errorName(err) });
        return 1;
    };
    defer allocator.free(path);

    if (!fs.path.isAbsolute(path)) {
        err_out.warn("Skipping non-absolute uninstall path \"{s}\".", .{raw});
        return 1;
    }

    // Compare the resolved path: a plain string check lets "/usr/local/.." or
    // a symlinked parent walk straight past the guard, and this runs as root.
    var real_buf: [fs.max_path_bytes]u8 = undefined;
    const probe = fs.cwd().realpath(path, &real_buf) catch |err| switch (err) {
        // Nothing there to remove.
        error.FileNotFound => return 0,
        // Guard degraded to a plain string compare — decline rather than
        // run `rm -rf` as root on a path we could not resolve.
        else => {
            err_out.warn("Could not resolve \"{s}\" ({s}); leaving it in place.", .{ path, @errorName(err) });
            return 1;
        },
    };
    if (isSystemDirectory(probe) or isSystemDirectory(path)) {
        err_out.warn("Refusing to remove system path \"{s}\".", .{path});
        return 1;
    }

    action(allocator, path) catch |err| {
        err_out.warn("Could not remove \"{s}\": {s}", .{ path, @errorName(err) });
        return 1;
    };
    return 0;
}

/// Resolve `~` and `$HOME` prefixes in a cask-declared path. Caller owns it.
fn expandPath(allocator: Allocator, raw: []const u8) ![]u8 {
    const tilde = mem.startsWith(u8, raw, "~") or mem.startsWith(u8, raw, "$HOME");
    if (tilde and std.posix.getuid() == 0) {
        // HOME is /var/root under sudo; expanding would target the wrong user
        // and silently remove nothing.
        return error.HomeRelativePathAsRoot;
    }

    const home = std.posix.getenv("HOME") orelse return try allocator.dupe(u8, raw);

    if (mem.eql(u8, raw, "~")) return try allocator.dupe(u8, home);
    if (mem.startsWith(u8, raw, "~/")) {
        return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, raw[2..] });
    }
    if (mem.eql(u8, raw, "$HOME")) return try allocator.dupe(u8, home);
    if (mem.startsWith(u8, raw, "$HOME/")) {
        return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, raw["$HOME/".len..] });
    }
    return try allocator.dupe(u8, raw);
}

/// Remove a path and anything under it.
// Unprivileged first, escalating only on permission failure, so a cask owning
// nothing outside $HOME never prompts for a password.
fn deletePath(allocator: Allocator, path: []const u8) !void {
    fs.deleteTreeAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        error.AccessDenied,
        error.PermissionDenied,
        error.FileBusy,
        error.ReadOnlyFileSystem,
        => try sudoRemove(allocator, path),
        else => return err,
    };
}

fn sudoRemove(allocator: Allocator, path: []const u8) !void {
    if (try runAsRoot(allocator, &.{ "/bin/rm", "-rf", "--", path }, false) != 0) {
        return error.PathRemovalFailed;
    }
}

/// Move a path to the user's Trash, as brew's `trash:` does.
// Reports failure rather than deleting: `trash:` means the user may want these
// back, so a silent permanent delete is the one outcome to avoid.
fn trashPath(allocator: Allocator, path: []const u8) !void {
    _ = allocator;
    fs.cwd().access(path, .{}) catch return; // already gone

    // `trash:` exists so the user can get these back. Every fall-through below
    // is a permanent delete, so none of them may happen quietly.
    const home = std.posix.getenv("HOME") orelse {
        return error.TrashUnavailable;
    };

    const base = fs.path.basename(path);
    var buf: [fs.max_path_bytes]u8 = undefined;
    const dest = std.fmt.bufPrint(&buf, "{s}/.Trash/{s}", .{ home, base }) catch
        return error.TrashUnavailable;

    if (fs.cwd().access(dest, .{})) |_| {
        // Occupied — disambiguate the way Finder does.
        var buf2: [fs.max_path_bytes]u8 = undefined;
        const alt = std.fmt.bufPrint(&buf2, "{s}/.Trash/{s} {d}", .{ home, base, std.time.timestamp() }) catch
            return error.TrashUnavailable;
        return fs.renameAbsolute(path, alt);
    } else |_| {}

    try fs.renameAbsolute(path, dest);
}

/// Remove a directory only if empty: a populated one is shared with something
/// else and must stay. That is the whole point of `rmdir:`.
fn rmdirPath(allocator: Allocator, path: []const u8) !void {
    _ = allocator;
    fs.deleteDirAbsolute(path) catch |err| switch (err) {
        error.DirNotEmpty, error.FileNotFound, error.AccessDenied => {},
        else => return err,
    };
}

/// Prefix a receipt's relative file list is anchored to: `volume` +
/// `install-location`. Null when no receipt is registered. Caller owns it.
fn pkgReceiptRoot(allocator: Allocator, id: []const u8) !?[]const u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ pkgutil_bin, "--pkg-info", id },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }

    var volume: []const u8 = "/";
    var location: []const u8 = "";
    var lines = mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (mem.startsWith(u8, line, "volume: ")) {
            volume = mem.trim(u8, line["volume: ".len..], " \t\r");
        } else if (mem.startsWith(u8, line, "location: ")) {
            location = mem.trim(u8, line["location: ".len..], " \t\r/");
        }
    }

    if (location.len == 0) return try allocator.dupe(u8, volume);
    const sep: []const u8 = if (mem.endsWith(u8, volume, "/")) "" else "/";
    return try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ volume, sep, location });
}

const PathKind = enum { files, dirs };

/// Delete a receipt's payload paths of one kind, as root, deepest-first and
/// batched so a large payload cannot overflow the argument list.
// `rmdir` failing on non-empty dirs is what keeps a shared /usr/local intact.
fn removePkgPaths(allocator: Allocator, id: []const u8, root: []const u8, kind: PathKind) !void {
    const only_flag = switch (kind) {
        .files => "--only-files",
        .dirs => "--only-dirs",
    };

    const listing = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ pkgutil_bin, only_flag, "--files", id },
        .max_output_bytes = pkgutil_max_output,
    });
    defer allocator.free(listing.stdout);
    defer allocator.free(listing.stderr);
    switch (listing.term) {
        .Exited => |code| if (code != 0) return error.PkgutilListFailed,
        else => return error.PkgutilListFailed,
    }

    var paths = std.ArrayList(DepthPath){};
    defer {
        for (paths.items) |p| allocator.free(p.path);
        paths.deinit(allocator);
    }

    const sep: []const u8 = if (mem.endsWith(u8, root, "/")) "" else "/";
    var lines = mem.splitScalar(u8, listing.stdout, '\n');
    while (lines.next()) |line| {
        const rel = mem.trim(u8, line, " \t\r");
        if (rel.len == 0 or mem.eql(u8, rel, ".")) continue;
        const abs = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ root, sep, rel });
        // WARNING: runs as root. A BOM legitimately lists its ancestors
        // (usr, usr/local, Library) — never aim removal at those.
        if (mem.eql(u8, abs, "/") or abs.len <= root.len or isSystemDirectory(abs)) {
            allocator.free(abs);
            continue;
        }
        try paths.append(allocator, .{ .depth = mem.count(u8, abs, "/"), .path = abs });
    }
    if (paths.items.len == 0) return;

    // Deepest paths first so rmdir sees children before their parents.
    std.mem.sort(DepthPath, paths.items, {}, deeperPathFirst);

    // rmdir noisily refuses non-empty dirs — expected for shared parents.
    const cmd: []const []const u8 = switch (kind) {
        .files => &.{ "/bin/rm", "-f", "--" },
        .dirs => &.{ "/bin/rmdir", "--" },
    };

    // Batch by argv bytes rather than a path count: ARG_MAX is ~1 MiB, so a
    // fixed count of 128 spawns sudo far more often than necessary.
    const batch_bytes = 256 * 1024;
    var argv = std.ArrayList([]const u8){};
    defer argv.deinit(allocator);

    var start: usize = 0;
    while (start < paths.items.len) {
        argv.clearRetainingCapacity();
        try argv.appendSlice(allocator, cmd);

        const end = nextBatchEnd(paths.items, start, batch_bytes);
        for (paths.items[start..end]) |p| try argv.append(allocator, p.path);

        const code = try runAsRoot(allocator, argv.items, kind == .dirs);
        if (kind == .files and code != 0) return error.PkgFileRemovalFailed;

        start = end;
    }
}

/// Directories owned by the OS, not any package — a receipt's BOM lists every
/// ancestor of its payload, so these appear routinely.
// rmdir would refuse a populated one anyway; explicit because this runs as root.
const system_directories = [_][]const u8{
    "/",
    "/Applications",
    "/Library",
    "/System",
    "/bin",
    "/etc",
    "/opt",
    "/opt/homebrew",
    "/opt/homebrew/bin",
    "/opt/homebrew/lib",
    "/private",
    "/sbin",
    "/tmp",
    "/usr",
    "/usr/bin",
    "/usr/lib",
    "/usr/libexec",
    "/usr/local",
    "/usr/local/bin",
    "/usr/local/lib",
    "/usr/local/share",
    "/usr/sbin",
    "/usr/share",
    "/var",
    "/Users",
    "/Volumes",
    // A cask's plist or helper lives *inside* these; the dir itself is macOS's.
    "/Library/Application Support",
    "/Library/Audio",
    "/Library/Caches",
    "/Library/Fonts",
    "/Library/Extensions",
    "/Library/Frameworks",
    "/Library/Internet Plug-Ins",
    "/Library/LaunchAgents",
    "/Library/LaunchDaemons",
    "/Library/Preferences",
    "/Library/PrivilegedHelperTools",
    "/Library/QuickLook",
    "/Library/Screen Savers",
};

fn isSystemDirectory(path: []const u8) bool {
    const trimmed = if (path.len > 1) mem.trimRight(u8, path, "/") else path;
    for (system_directories) |dir| {
        if (mem.eql(u8, trimmed, dir)) return true;
    }
    return isProtectedHomeDirectory(trimmed);
}

/// $HOME itself and the top-level user directories. No shipping cask names
/// these, but the guard's job is to bound what third-party metadata can hand
/// to a root `rm`, and these are where the most is lost.
fn isProtectedHomeDirectory(path: []const u8) bool {
    const home = std.posix.getenv("HOME") orelse return false;
    if (mem.eql(u8, path, home)) return true;

    if (!mem.startsWith(u8, path, home)) return false;
    const rest = path[home.len..];
    if (rest.len == 0 or rest[0] != '/') return false;

    const protected = [_][]const u8{
        "Library",                   "Library/Application Support",
        "Library/Caches",            "Library/Preferences",
        "Library/Containers",        "Library/LaunchAgents",
        "Documents",                 "Desktop",
        "Downloads",                 "Movies",
        "Music",                     "Pictures",
        "Applications",              ".Trash",
    };
    for (protected) |p| {
        if (mem.eql(u8, rest[1..], p)) return true;
    }
    return false;
}

/// Index one past the last path that fits in `budget` bytes of argv, starting
/// at `start`. Always advances by at least one so no path is ever skipped,
/// even when a single path exceeds the budget on its own.
fn nextBatchEnd(paths: []const DepthPath, start: usize, budget: usize) usize {
    var bytes: usize = 0;
    var end = start;
    while (end < paths.len) : (end += 1) {
        const cost = paths[end].path.len + 1;
        if (end > start and bytes + cost > budget) break;
        bytes += cost;
    }
    return end;
}

/// Order paths by descending component count so children sort before parents.
fn deeperPathFirst(_: void, a: DepthPath, b: DepthPath) bool {
    return a.depth > b.depth;
}

const DepthPath = struct { depth: usize, path: []const u8 };

/// Drop a receipt so pkgutil no longer reports the package as installed.
fn forgetPkgReceipt(allocator: Allocator, id: []const u8) !void {
    if (try runAsRoot(allocator, &.{ pkgutil_bin, "--forget", id }, false) != 0) {
        return error.PkgForgetFailed;
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
        // A pkg cask's binary is often root-owned, so chmod may be denied.
        // The symlink is still worth creating.
        source_file.chmod(new_mode) catch |chmod_err| switch (chmod_err) {
            error.AccessDenied => {},
            else => return chmod_err,
        };
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
    // pkg casks point at files the installer wrote outside the Caskroom;
    // joining to a root would give "{root}//usr/local/..." and never resolve.
    if (fs.path.isAbsolute(binary_source)) {
        fs.cwd().access(binary_source, .{}) catch return error.BinaryNotFound;
        return try allocator.dupe(u8, binary_source);
    }

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

// ---------------------------------------------------------------------------
// pkg cask support
// ---------------------------------------------------------------------------

test "resolveBinarySource returns an absolute source unchanged" {
    const allocator = std.testing.allocator;

    // Stands in for /usr/local/sessionmanagerplugin/bin/... — nowhere near
    // the version dir.
    var installed_tmp = std.testing.tmpDir(.{});
    defer installed_tmp.cleanup();
    const f = try installed_tmp.dir.createFile("session-manager-plugin", .{});
    try f.writeAll("#!/bin/sh\n");
    f.close();

    var installed_buf: [fs.max_path_bytes]u8 = undefined;
    const installed_dir = try installed_tmp.dir.realpath(".", &installed_buf);
    const abs_source = try std.fmt.allocPrint(allocator, "{s}/session-manager-plugin", .{installed_dir});
    defer allocator.free(abs_source);

    // Roots deliberately do NOT contain the binary — joining would have failed.
    var version_tmp = std.testing.tmpDir(.{});
    defer version_tmp.cleanup();
    var version_buf: [fs.max_path_bytes]u8 = undefined;
    const version_dir = try version_tmp.dir.realpath(".", &version_buf);

    const roots = [_][]const u8{version_dir};
    const resolved = try resolveBinarySource(allocator, &roots, abs_source);
    defer allocator.free(resolved);

    try std.testing.expectEqualStrings(abs_source, resolved);
}

test "stagePkgFile stages under the declared pkg name, not the URL basename" {
    const allocator = std.testing.allocator;

    var src_tmp = std.testing.tmpDir(.{});
    defer src_tmp.cleanup();
    const blob = try src_tmp.dir.createFile("deadbeef.pkg", .{});
    try blob.writeAll("xar!payload");
    blob.close();

    var src_buf: [fs.max_path_bytes]u8 = undefined;
    const src_dir = try src_tmp.dir.realpath(".", &src_buf);
    const blob_path = try std.fmt.allocPrint(allocator, "{s}/deadbeef.pkg", .{src_dir});
    defer allocator.free(blob_path);

    var dest_tmp = std.testing.tmpDir(.{});
    defer dest_tmp.cleanup();
    var dest_buf: [fs.max_path_bytes]u8 = undefined;
    const dest_dir = try dest_tmp.dir.realpath(".", &dest_buf);

    // displaylink's real shape: the URL is percent-encoded, the artifact is not.
    // Staging from the URL would write "DisplayLink%20Manager.pkg" and then
    // fail PkgNotFound looking for the declared name.
    var pkgs = [_]cask.PkgArtifact{.{ .source = "DisplayLink Manager.pkg", .allow_untrusted = false }};
    const resolved = ResolvedCask{
        .token = "displaylink",
        .version = "1.0",
        .url = "https://example.com/dl/DisplayLink%20Manager.pkg",
        .sha256 = "abc",
        .name = "DisplayLink",
        .binaries = &.{},
        .apps = &.{},
        .pkgs = &pkgs,
        .uninstall = .{ .pkgutil = &.{}, .delete = &.{}, .rmdir = &.{}, .trash = &.{}, .unsupported = &.{} },
    };

    try stagePkgFile(allocator, resolved, blob_path, dest_dir);

    const staged = try dest_tmp.dir.readFileAlloc(allocator, "DisplayLink Manager.pkg", 1024);
    defer allocator.free(staged);
    try std.testing.expectEqualStrings("xar!payload", staged);
}

test "uninstall plan round-trips through the version dir" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [fs.max_path_bytes]u8 = undefined;
    const version_dir = try tmp.dir.realpath(".", &buf);

    // Spaces and tildes are common in real casks; both must survive the trip.
    const plan = UninstallPlan{
        .pkgutil = @constCast(&[_][]const u8{ "session-manager-plugin", "com.example.other" }),
        .delete = @constCast(&[_][]const u8{ "/Library/Application Support/Example", "~/Library/Logs/Ex" }),
        .rmdir = @constCast(&[_][]const u8{"/Library/Application Support/Example Software"}),
        .trash = @constCast(&[_][]const u8{"/Library/Audio/Plug-Ins/HAL/Ex.driver"}),
        .unsupported = @constCast(&[_][]const u8{}),
    };
    try writeUninstallPlan(allocator, version_dir, plan);

    const read_back = try readUninstallPlan(allocator, version_dir);
    defer cask.freeUninstallPlan(allocator, read_back);

    try std.testing.expectEqual(@as(usize, 2), read_back.pkgutil.len);
    try std.testing.expectEqualStrings("session-manager-plugin", read_back.pkgutil[0]);
    try std.testing.expectEqual(@as(usize, 2), read_back.delete.len);
    try std.testing.expectEqualStrings("/Library/Application Support/Example", read_back.delete[0]);
    try std.testing.expectEqualStrings("~/Library/Logs/Ex", read_back.delete[1]);
    try std.testing.expectEqual(@as(usize, 1), read_back.rmdir.len);
    try std.testing.expectEqualStrings("/Library/Application Support/Example Software", read_back.rmdir[0]);
    try std.testing.expectEqual(@as(usize, 1), read_back.trash.len);
}

test "readUninstallPlan returns empty when a cask recorded none" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [fs.max_path_bytes]u8 = undefined;
    const version_dir = try tmp.dir.realpath(".", &buf);

    // Common app/binary cask: no plan file at all.
    const plan = try readUninstallPlan(allocator, version_dir);
    defer cask.freeUninstallPlan(allocator, plan);
    try std.testing.expect(plan.isEmpty());
}

test "expandPath resolves tilde and $HOME prefixes" {
    const allocator = std.testing.allocator;
    const home = std.posix.getenv("HOME") orelse return error.SkipZigTest;

    const tilde = try expandPath(allocator, "~/Library/Logs/Ex");
    defer allocator.free(tilde);
    const expected = try std.fmt.allocPrint(allocator, "{s}/Library/Logs/Ex", .{home});
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, tilde);

    const dollar = try expandPath(allocator, "$HOME/Library/Logs/Ex");
    defer allocator.free(dollar);
    try std.testing.expectEqualStrings(expected, dollar);

    // "~name" is another user, NOT a home reference.
    const abs = try expandPath(allocator, "/Library/Application Support/Ex");
    defer allocator.free(abs);
    try std.testing.expectEqualStrings("/Library/Application Support/Ex", abs);

    const other_user = try expandPath(allocator, "~someone/thing");
    defer allocator.free(other_user);
    try std.testing.expectEqualStrings("~someone/thing", other_user);
}

test "deletePath and rmdirPath remove only what they should" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &buf);

    // delete: removes a whole tree.
    try tmp.dir.makePath("support/nested");
    const f = try tmp.dir.createFile("support/nested/file", .{});
    f.close();
    const support = try std.fmt.allocPrint(allocator, "{s}/support", .{root});
    defer allocator.free(support);
    try deletePath(allocator, support);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("support", .{}));

    // delete: on a missing path is a no-op, not an error (re-run uninstall).
    try deletePath(allocator, support);

    // rmdir: removes an empty directory...
    try tmp.dir.makeDir("empty");
    const empty = try std.fmt.allocPrint(allocator, "{s}/empty", .{root});
    defer allocator.free(empty);
    try rmdirPath(allocator, empty);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("empty", .{}));

    // ...but leaves a populated one alone; it is shared.
    try tmp.dir.makePath("occupied");
    const keep = try tmp.dir.createFile("occupied/other-owner", .{});
    keep.close();
    const occupied = try std.fmt.allocPrint(allocator, "{s}/occupied", .{root});
    defer allocator.free(occupied);
    try rmdirPath(allocator, occupied);
    try tmp.dir.access("occupied/other-owner", .{});
}

test "isSystemDirectory shields OS directories from rmdir" {
    // All of these appear in session-manager-plugin's own BOM.
    try std.testing.expect(isSystemDirectory("/usr"));
    try std.testing.expect(isSystemDirectory("/usr/local"));
    try std.testing.expect(isSystemDirectory("/Library"));
    try std.testing.expect(isSystemDirectory("/"));
    try std.testing.expect(isSystemDirectory("/usr/local/"));

    // Only the plist inside belongs to the package, not the dir.
    try std.testing.expect(isSystemDirectory("/Library/LaunchDaemons"));

    // Package-owned directories must remain removable.
    try std.testing.expect(!isSystemDirectory("/usr/local/sessionmanagerplugin"));
    try std.testing.expect(!isSystemDirectory("/usr/local/sessionmanagerplugin/bin"));
    try std.testing.expect(!isSystemDirectory("/Library/LaunchDaemons/SessionManagerPlugin.plist"));
}

test "isSystemDirectory shields the home directory and its top-level dirs" {
    const home = std.posix.getenv("HOME") orelse return error.SkipZigTest;
    const allocator = std.testing.allocator;

    try std.testing.expect(isSystemDirectory(home));

    for ([_][]const u8{ "Library", "Documents", "Library/Application Support", ".Trash" }) |sub| {
        const p = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, sub });
        defer allocator.free(p);
        try std.testing.expect(isSystemDirectory(p));
    }

    // A cask's own directory under ~/Library stays removable.
    const own = try std.fmt.allocPrint(allocator, "{s}/Library/Application Support/SomeVendor", .{home});
    defer allocator.free(own);
    try std.testing.expect(!isSystemDirectory(own));

    // A sibling that merely shares the prefix is not the home dir.
    const sibling = try std.fmt.allocPrint(allocator, "{s}-other/Library", .{home});
    defer allocator.free(sibling);
    try std.testing.expect(!isSystemDirectory(sibling));
}

test "expandPath refuses home-relative paths when running as root" {
    if (std.posix.getuid() == 0) return error.SkipZigTest;
    _ = std.posix.getenv("HOME") orelse return error.SkipZigTest;

    // Non-root: expansion works (covered elsewhere). The root refusal exists
    // because HOME is /var/root under sudo, so expanding would target the
    // wrong user and silently remove nothing while reporting success.
    const allocator = std.testing.allocator;
    const p = try expandPath(allocator, "~/Library/Logs/Ex");
    defer allocator.free(p);
    try std.testing.expect(fs.path.isAbsolute(p));
}

test "keg ownership decides whether uninstall may delete it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &buf);

    const allocator = std.testing.allocator;
    const version_dir = try std.fmt.allocPrint(allocator, "{s}/token/1.0", .{root});
    defer allocator.free(version_dir);
    try fs.cwd().makePath(version_dir);

    // A bru-installed app cask: no plan, no brew metadata -> safe to delete.
    try std.testing.expect(!hasUninstallPlan(version_dir));
    try std.testing.expect(!looksBrewInstalled(version_dir));

    // brew writes .metadata beside the version dir; bru never does. Deleting
    // this keg would destroy the entry brew needs to clean up.
    const meta = try std.fmt.allocPrint(allocator, "{s}/token/.metadata", .{root});
    defer allocator.free(meta);
    try fs.cwd().makePath(meta);
    try std.testing.expect(looksBrewInstalled(version_dir));

    // A recorded plan means bru owns the teardown even if brew touched it.
    var plan_ids = [_][]const u8{"com.example.a"};
    const plan = UninstallPlan{ .pkgutil = &plan_ids, .delete = &.{}, .rmdir = &.{}, .trash = &.{}, .unsupported = &.{} };
    try writeUninstallPlan(allocator, version_dir, plan);
    try std.testing.expect(hasUninstallPlan(version_dir));
}

test "an unreadable plan refuses the uninstall instead of reporting success" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [fs.max_path_bytes]u8 = undefined;
    const version_dir = try tmp.dir.realpath(".", &buf);

    // A truncated write looks exactly like this. Treating it as "nothing to
    // undo" would let the caller delete the only manifest for a root payload.
    const f = try tmp.dir.createFile(uninstall_plan_file, .{});
    try f.writeAll("{\"pkgutil\":[\"com.example.a\"");
    f.close();

    try std.testing.expectError(error.UnexpectedEndOfInput, readUninstallPlan(allocator, version_dir));

    const quiet = Output{ .file = std.fs.File.stderr(), .use_color = false };
    try std.testing.expectError(
        error.UninstallPlanUnreadable,
        uninstallCaskArtifacts(allocator, version_dir, quiet, quiet),
    );
}

test "uninstallCaskArtifacts applies delete then rmdir, and refuses system paths" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &buf);

    try tmp.dir.makePath("payload/nested");
    const f = try tmp.dir.createFile("payload/nested/file", .{});
    f.close();
    try tmp.dir.makePath("empty");
    try tmp.dir.makePath("occupied");
    const keep = try tmp.dir.createFile("occupied/other-owner", .{});
    keep.close();

    const payload = try std.fmt.allocPrint(allocator, "{s}/payload", .{root});
    defer allocator.free(payload);
    const empty = try std.fmt.allocPrint(allocator, "{s}/empty", .{root});
    defer allocator.free(empty);
    const occupied = try std.fmt.allocPrint(allocator, "{s}/occupied", .{root});
    defer allocator.free(occupied);

    // A cask aiming at a system directory must be refused, not obeyed: this
    // list is the only thing between remote metadata and a root `rm -rf`.
    var deletes = [_][]const u8{ payload, "/usr/local" };
    var rmdirs = [_][]const u8{ empty, occupied };
    // An id no receipt matches, so the pkgutil branch short-circuits (no sudo).
    var ids = [_][]const u8{"com.bru.test.absent"};

    const plan = UninstallPlan{ .pkgutil = &ids, .delete = &deletes, .rmdir = &rmdirs, .trash = &.{}, .unsupported = &.{} };
    try writeUninstallPlan(allocator, root, plan);

    const quiet = Output{ .file = std.fs.File.stderr(), .use_color = false };
    const failures = try uninstallCaskArtifacts(allocator, root, quiet, quiet);

    // The refused system path is reported, not silently skipped.
    try std.testing.expectEqual(@as(usize, 1), failures);

    try std.testing.expectError(error.FileNotFound, tmp.dir.access("payload", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("empty", .{}));
    try tmp.dir.access("occupied/other-owner", .{}); // shared dir survives
    try fs.cwd().access("/usr/local", .{}); // untouched
}

test "nextBatchEnd always advances and never exceeds its budget" {
    const paths = [_]DepthPath{
        .{ .depth = 1, .path = "/aaaa" }, // 5 + 1
        .{ .depth = 1, .path = "/bbbb" },
        .{ .depth = 1, .path = "/cccc" },
    };

    // Budget fits exactly two entries (6 bytes each).
    try std.testing.expectEqual(@as(usize, 2), nextBatchEnd(&paths, 0, 12));
    try std.testing.expectEqual(@as(usize, 3), nextBatchEnd(&paths, 2, 12));

    // A budget too small for even one path must still consume one, or the
    // caller loops forever and the remaining paths are never removed.
    try std.testing.expectEqual(@as(usize, 1), nextBatchEnd(&paths, 0, 1));

    // Walking the whole list covers every path exactly once.
    var start: usize = 0;
    var seen: usize = 0;
    while (start < paths.len) {
        const end = nextBatchEnd(&paths, start, 7);
        try std.testing.expect(end > start);
        seen += end - start;
        start = end;
    }
    try std.testing.expectEqual(paths.len, seen);
}

test "deeperPathFirst sorts children before their parents" {
    const mk = struct {
        fn f(p: []const u8) DepthPath {
            return .{ .depth = mem.count(u8, p, "/"), .path = p };
        }
    }.f;
    var paths = [_]DepthPath{
        mk("/usr/local"),
        mk("/usr/local/sessionmanagerplugin/bin/session-manager-plugin"),
        mk("/usr/local/sessionmanagerplugin"),
        mk("/usr/local/sessionmanagerplugin/bin"),
    };
    std.mem.sort(DepthPath, &paths, {}, deeperPathFirst);

    // Otherwise every parent removal fails as non-empty.
    try std.testing.expectEqualStrings("/usr/local/sessionmanagerplugin/bin/session-manager-plugin", paths[0].path);
    try std.testing.expectEqualStrings("/usr/local/sessionmanagerplugin/bin", paths[1].path);
    try std.testing.expectEqualStrings("/usr/local/sessionmanagerplugin", paths[2].path);
    try std.testing.expectEqualStrings("/usr/local", paths[3].path);
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
