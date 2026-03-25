const std = @import("std");
const builtin = @import("builtin");
const Config = @import("../config.zig").Config;
const Output = @import("../output.zig").Output;
const HttpClient = @import("../http.zig").HttpClient;
const build_options = @import("build_options");

const repo = "zieka/bru";
const releases_url = "https://api.github.com/repos/" ++ repo ++ "/releases/latest";

/// Self-update command — check for and install the latest bru release.
///
/// Usage: bru self-update [--check] [--force]
///
/// Options:
///   --check  Check for updates without installing
///   --force  Re-download even if already up-to-date
pub fn selfUpdateCmd(allocator: std.mem.Allocator, args: []const []const u8, config: Config) anyerror!void {
    const out = Output.init(config.no_color);
    const err_out = Output.initErr(config.no_color);

    // Parse flags.
    var check_only = false;
    var force = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--check")) {
            check_only = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        }
    }

    out.print("bru {s}\n", .{build_options.version});

    // Print path to the running binary.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_exe_path = std.fs.selfExePath(&path_buf) catch {
        err_out.err("Could not determine binary path.\n", .{});
        return error.SelfExeNotFound;
    };
    out.print("Binary: {s}\n", .{self_exe_path});

    // Query GitHub Releases API.
    out.print("Checking for updates...\n", .{});

    var http = HttpClient.init(allocator);
    defer http.deinit();

    const body = http.fetchToMemory(allocator, releases_url) catch {
        err_out.err("Failed to check for updates — could not reach GitHub.\n", .{});
        return error.NetworkError;
    };
    defer allocator.free(body);

    // Parse release JSON.
    var release = parseRelease(allocator, body) catch {
        err_out.err("Failed to parse release information from GitHub.\n", .{});
        return error.ParseError;
    };
    defer release.deinit();

    const latest_version = release.version;
    out.print("Latest:  {s}\n", .{latest_version});

    // Compare versions.
    const current = parseSemver(build_options.version) catch {
        err_out.err("Could not parse current version.\n", .{});
        return error.ParseError;
    };
    const latest = parseSemver(latest_version) catch {
        err_out.err("Could not parse latest version.\n", .{});
        return error.ParseError;
    };

    const cmp = compareSemver(current, latest);
    if (cmp != .lt and !force) {
        out.print("Already up-to-date.\n", .{});
        return;
    }

    if (check_only) {
        out.section("Update available");
        out.print("{s} -> {s}\n", .{ build_options.version, latest_version });
        out.print("Run `bru self-update` to install.\n", .{});
        return;
    }

    // Find the download URL for the current platform.
    const asset_name = comptime assetName();
    const download_url = findAssetUrl(release.parsed.value.assets, asset_name) orelse {
        err_out.err("No release asset found for {s}.\n", .{asset_name});
        return error.AssetNotFound;
    };

    // Download to a temp file.
    out.section("Downloading");
    out.print("{s}\n", .{download_url});

    const tmp_path = "/tmp/bru-self-update";
    http.fetch(download_url, tmp_path) catch {
        err_out.err("Failed to download update.\n", .{});
        return error.DownloadFailed;
    };

    // Make the downloaded binary executable.
    {
        const f = std.fs.cwd().openFile(tmp_path, .{}) catch {
            err_out.err("Failed to open downloaded binary.\n", .{});
            return error.FileError;
        };
        defer f.close();
        f.chmod(0o755) catch {
            err_out.err("Failed to set executable permission.\n", .{});
            return error.FileError;
        };
    }

    // Install: try direct rename, fall back to sudo.
    out.section("Installing");
    installBinary(allocator, tmp_path, self_exe_path) catch {
        err_out.err("Failed to install update.\n", .{});
        return error.InstallFailed;
    };

    out.print("bru updated: {s} -> {s}\n", .{ build_options.version, latest_version });
}

// ---------------------------------------------------------------------------
// Release JSON parsing
// ---------------------------------------------------------------------------

/// Minimal JSON structure matching the GitHub Releases API response.
const GitHubRelease = struct {
    tag_name: []const u8,
    assets: []const GitHubAsset,
};

const GitHubAsset = struct {
    name: []const u8,
    browser_download_url: []const u8,
};

const ParsedRelease = struct {
    parsed: std.json.Parsed(GitHubRelease),
    version: []const u8,

    fn deinit(self: *ParsedRelease) void {
        self.parsed.deinit();
    }
};

fn parseRelease(allocator: std.mem.Allocator, body: []const u8) !ParsedRelease {
    const parsed = try std.json.parseFromSlice(GitHubRelease, allocator, body, .{
        .ignore_unknown_fields = true,
    });

    const tag = parsed.value.tag_name;

    // Strip leading "v" if present (e.g. "v0.2.0" -> "0.2.0").
    const version = if (tag.len > 0 and tag[0] == 'v') tag[1..] else tag;

    return .{
        .parsed = parsed,
        .version = version,
    };
}

fn findAssetUrl(assets: []const GitHubAsset, name: []const u8) ?[]const u8 {
    for (assets) |asset| {
        if (std.mem.eql(u8, asset.name, name)) {
            return asset.browser_download_url;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Platform detection
// ---------------------------------------------------------------------------

fn assetName() []const u8 {
    const arch: []const u8 = switch (builtin.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => @compileError("unsupported architecture for self-update"),
    };
    return "bru-darwin-" ++ arch;
}

// ---------------------------------------------------------------------------
// Semver comparison
// ---------------------------------------------------------------------------

const Semver = struct {
    major: u32,
    minor: u32,
    patch: u32,
};

fn parseSemver(s: []const u8) !Semver {
    var parts = std.mem.splitScalar(u8, s, '.');
    const major = std.fmt.parseInt(u32, parts.next() orelse return error.InvalidVersion, 10) catch return error.InvalidVersion;
    const minor = std.fmt.parseInt(u32, parts.next() orelse return error.InvalidVersion, 10) catch return error.InvalidVersion;
    const patch = std.fmt.parseInt(u32, parts.next() orelse return error.InvalidVersion, 10) catch return error.InvalidVersion;
    return .{ .major = major, .minor = minor, .patch = patch };
}

fn compareSemver(a: Semver, b: Semver) std.math.Order {
    if (a.major != b.major) return std.math.order(a.major, b.major);
    if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
    return std.math.order(a.patch, b.patch);
}

// ---------------------------------------------------------------------------
// Binary installation
// ---------------------------------------------------------------------------

fn installBinary(allocator: std.mem.Allocator, tmp_path: []const u8, dest_path: []const u8) !void {
    // Try direct rename (atomic, works if same filesystem and writable).
    if (renameFile(tmp_path, dest_path)) {
        return;
    } else |err| switch (err) {
        error.AccessDenied => return try sudoInstall(allocator, tmp_path, dest_path),
        error.RenameAcrossMountPoints => {}, // fall through to copy approach
        else => return err,
    }

    // Cross-filesystem: copy content over. On Unix we can unlink a running
    // binary (the old inode stays alive until the process exits), then write
    // a fresh file at the same path.
    copyOverFile(tmp_path, dest_path) catch |err| {
        if (err == error.AccessDenied) {
            return try sudoInstall(allocator, tmp_path, dest_path);
        }
        return err;
    };
}

fn renameFile(old: []const u8, new: []const u8) !void {
    const old_z = try std.posix.toPosixPath(old);
    const new_z = try std.posix.toPosixPath(new);
    try std.posix.rename(&old_z, &new_z);
}

fn copyOverFile(src_path: []const u8, dest_path: []const u8) !void {
    // Read source into a stack-friendly streaming copy.
    const src = try std.fs.cwd().openFile(src_path, .{});
    defer src.close();

    // Delete the destination first (unlinking a running binary is fine on Unix).
    std.fs.cwd().deleteFile(dest_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const dest = try std.fs.cwd().createFile(dest_path, .{ .mode = 0o755 });
    defer dest.close();

    // Stream copy.
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try src.read(&buf);
        if (n == 0) break;
        try dest.writeAll(buf[0..n]);
    }
}

fn sudoInstall(allocator: std.mem.Allocator, tmp_path: []const u8, dest_path: []const u8) !void {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "sudo", "mv", tmp_path, dest_path },
    });
    const r = result catch return error.SudoFailed;
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    if (r.term.Exited != 0) return error.SudoFailed;

    // Ensure executable permission after sudo mv.
    const chmod_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "sudo", "chmod", "+x", dest_path },
    });
    const cr = chmod_result catch return error.SudoFailed;
    defer allocator.free(cr.stdout);
    defer allocator.free(cr.stderr);
    if (cr.term.Exited != 0) return error.SudoFailed;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "selfUpdateCmd compiles and has correct signature" {
    const handler: @import("../dispatch.zig").CommandFn = selfUpdateCmd;
    _ = handler;
}

test "current version is a valid semver string" {
    if (std.mem.eql(u8, build_options.version, "dev")) return; // skip in local dev builds
    const v = try parseSemver(build_options.version);
    try std.testing.expect(v.major < 1000);
}

test "parseSemver parses valid versions" {
    const v = try parseSemver("1.23.456");
    try std.testing.expectEqual(@as(u32, 1), v.major);
    try std.testing.expectEqual(@as(u32, 23), v.minor);
    try std.testing.expectEqual(@as(u32, 456), v.patch);
}

test "parseSemver rejects invalid input" {
    try std.testing.expectError(error.InvalidVersion, parseSemver("abc"));
    try std.testing.expectError(error.InvalidVersion, parseSemver("1.2"));
    try std.testing.expectError(error.InvalidVersion, parseSemver(""));
}

test "compareSemver ordering" {
    const v100 = Semver{ .major = 1, .minor = 0, .patch = 0 };
    const v110 = Semver{ .major = 1, .minor = 1, .patch = 0 };
    const v111 = Semver{ .major = 1, .minor = 1, .patch = 1 };
    const v200 = Semver{ .major = 2, .minor = 0, .patch = 0 };

    try std.testing.expectEqual(std.math.Order.eq, compareSemver(v100, v100));
    try std.testing.expectEqual(std.math.Order.lt, compareSemver(v100, v110));
    try std.testing.expectEqual(std.math.Order.lt, compareSemver(v110, v111));
    try std.testing.expectEqual(std.math.Order.lt, compareSemver(v111, v200));
    try std.testing.expectEqual(std.math.Order.gt, compareSemver(v200, v100));
}

test "assetName matches expected format" {
    const name = comptime assetName();
    try std.testing.expect(std.mem.startsWith(u8, name, "bru-darwin-"));
}

test "parseRelease extracts version and assets" {
    const json =
        \\{"tag_name":"v1.2.3","assets":[{"name":"bru-darwin-aarch64","browser_download_url":"https://example.com/aarch64"},{"name":"bru-darwin-x86_64","browser_download_url":"https://example.com/x86_64"}]}
    ;

    var release = try parseRelease(std.testing.allocator, json);
    defer release.deinit();
    try std.testing.expectEqualStrings("1.2.3", release.version);
    try std.testing.expectEqual(@as(usize, 2), release.parsed.value.assets.len);
    try std.testing.expectEqualStrings("bru-darwin-aarch64", release.parsed.value.assets[0].name);
}

test "findAssetUrl returns correct URL" {
    const json =
        \\{"tag_name":"v1.0.0","assets":[{"name":"bru-darwin-aarch64","browser_download_url":"https://example.com/arm"},{"name":"bru-darwin-x86_64","browser_download_url":"https://example.com/x86"}]}
    ;

    var release = try parseRelease(std.testing.allocator, json);
    defer release.deinit();
    const url = findAssetUrl(release.parsed.value.assets, "bru-darwin-aarch64");
    try std.testing.expect(url != null);
    try std.testing.expectEqualStrings("https://example.com/arm", url.?);

    const missing = findAssetUrl(release.parsed.value.assets, "bru-linux-aarch64");
    try std.testing.expect(missing == null);
}
