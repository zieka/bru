const std = @import("std");
const Config = @import("../config.zig").Config;
const Output = @import("../output.zig").Output;

/// Current bru version.
const current_version = "0.1.0";

/// Self-update command — display version info and scaffold future update support.
///
/// Usage: bru self-update [--check] [--force]
///
/// Options:
///   --check  Check for updates without installing
///   --force  Re-download even if already up-to-date
///
/// This command currently displays version information and binary path.
/// Actual self-update functionality will be implemented when release
/// infrastructure (GitHub Releases) is available.
///
// TODO: Future implementation plan:
// 1. Query GitHub Releases API for latest version tag
//    GET https://api.github.com/repos/<owner>/<repo>/releases/latest
// 2. Compare semver of current_version vs latest release tag
// 3. Download the appropriate binary for the current platform
// 4. Verify checksum / signature
// 5. Replace the running binary (atomic rename)
// 6. Print success message with old -> new version
pub fn selfUpdateCmd(_: std.mem.Allocator, args: []const []const u8, config: Config) anyerror!void {
    const out = Output.init(config.no_color);
    const err_out = Output.initErr(config.no_color);

    // Parse flags.
    var check = false;
    var force = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--check")) {
            check = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        }
    }

    // Always print current version.
    out.print("bru {s}\n", .{current_version});

    // Print path to the running binary.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fs.selfExePath(&path_buf)) |path| {
        out.print("Binary: {s}\n", .{path});
    } else |_| {
        out.print("Binary: (could not determine path)\n", .{});
    }

    if (check) {
        // TODO: Query GitHub Releases API to compare versions.
        err_out.warn("Self-update check is not yet available.\n", .{});
        return;
    }

    if (force) {
        // TODO: Force re-download even if versions match.
        err_out.warn("--force is specified but self-update is not yet available.\n", .{});
        return;
    }

    // Default: inform user that self-update is pending.
    out.print("Self-update is not yet available — release infrastructure pending.\n", .{});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "selfUpdateCmd compiles and has correct signature" {
    const handler: @import("../dispatch.zig").CommandFn = selfUpdateCmd;
    _ = handler;
}

test "current_version is a valid semver string" {
    // Verify the version string has the expected major.minor.patch format.
    var parts = std.mem.splitScalar(u8, current_version, '.');
    var count: usize = 0;
    while (parts.next()) |part| {
        _ = std.fmt.parseInt(u32, part, 10) catch unreachable;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}
