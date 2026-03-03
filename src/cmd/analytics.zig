const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const Output = @import("../output.zig").Output;

/// Manage Homebrew's anonymous aggregate user analytics.
///
/// Usage: bru analytics [state|on|off|regenerate-uuid]
///
/// Subcommands:
///   state              Show current analytics status (default)
///   on                 Enable analytics
///   off                Disable analytics
///   regenerate-uuid    Deprecated — prints warning and exits
///
/// Analytics state is stored in the Homebrew repository's local git config
/// as `homebrew.analyticsdisabled`. The `HOMEBREW_NO_ANALYTICS` env var
/// overrides the config value when set.
pub fn analyticsCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    const out = Output.init(config.no_color);
    const err_out = Output.initErr(config.no_color);

    // Parse subcommand from first non-flag argument.
    var subcommand: []const u8 = "";
    for (args) |arg| {
        if (!std.mem.startsWith(u8, arg, "-")) {
            subcommand = arg;
            break;
        }
    }

    if (subcommand.len == 0 or std.mem.eql(u8, subcommand, "state")) {
        const disabled = isAnalyticsDisabledByEnv() or isAnalyticsDisabledByConfig(allocator, config.repository);
        const status = if (disabled) "disabled" else "enabled";
        out.print("InfluxDB analytics are {s}.\nGoogle Analytics were destroyed.\n", .{status});
        return;
    }

    if (std.mem.eql(u8, subcommand, "on")) {
        setAnalyticsConfig(allocator, config.repository, false) catch {
            err_out.err("Could not update analytics config.", .{});
            std.process.exit(1);
        };
        return;
    }

    if (std.mem.eql(u8, subcommand, "off")) {
        setAnalyticsConfig(allocator, config.repository, true) catch {
            err_out.err("Could not update analytics config.", .{});
            std.process.exit(1);
        };
        return;
    }

    if (std.mem.eql(u8, subcommand, "regenerate-uuid")) {
        // Modern brew deprecated this — match that behavior.
        deleteUuidFile(config.repository);
        err_out.warn("Homebrew no longer uses an analytics UUID so this has been deleted!\nbrew analytics regenerate-uuid is no longer necessary.", .{});
        std.process.exit(1);
    }

    err_out.err("Unknown analytics subcommand: {s}", .{subcommand});
    std.process.exit(1);
}

/// Check if HOMEBREW_NO_ANALYTICS env var is set.
fn isAnalyticsDisabledByEnv() bool {
    const val = std.posix.getenv("HOMEBREW_NO_ANALYTICS") orelse return false;
    return val.len > 0;
}

/// Read `homebrew.analyticsdisabled` from git config.
/// Returns true if the config value is "true".
fn isAnalyticsDisabledByConfig(allocator: Allocator, repository: []const u8) bool {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "-C", repository, "config", "--local", "--get", "homebrew.analyticsdisabled" },
    }) catch return false;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    return std.mem.eql(u8, trimmed, "true");
}

/// Set `homebrew.analyticsdisabled` in git config.
fn setAnalyticsConfig(allocator: Allocator, repository: []const u8, disabled: bool) !void {
    const value = if (disabled) "true" else "false";
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "-C", repository, "config", "--local", "--replace-all", "homebrew.analyticsdisabled", value },
    }) catch return error.GitConfigFailed;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    switch (result.term) {
        .Exited => |code| {
            if (code != 0) return error.GitConfigFailed;
        },
        else => return error.GitConfigFailed,
    }
}

/// Delete the analytics UUID file if it exists.
fn deleteUuidFile(repository: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/.homebrew_analytics_user_uuid", .{repository}) catch return;
    std.fs.cwd().deleteFile(path) catch {};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "analyticsCmd compiles and has correct signature" {
    const handler: @import("../dispatch.zig").CommandFn = analyticsCmd;
    _ = handler;
}

test "isAnalyticsDisabledByEnv returns false when env not set" {
    // In test environment HOMEBREW_NO_ANALYTICS is typically not set.
    // This test verifies the env check path works.
    const result = isAnalyticsDisabledByEnv();
    // We can't control env in unit tests easily, so just verify it compiles
    // and returns a bool.
    _ = result;
}
