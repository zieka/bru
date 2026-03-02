const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const Index = @import("../index.zig").Index;
const cask_index_mod = @import("../cask_index.zig");
const CaskIndex = cask_index_mod.CaskIndex;
const Output = @import("../output.zig").Output;
const fuzzy = @import("../fuzzy.zig");

/// Open the homepage of a formula, cask, or Homebrew itself in the default browser.
///
/// Usage: bru home [formula|cask]
///
/// With no arguments, opens https://brew.sh. With a formula or cask name,
/// opens that package's homepage URL.
pub fn homeCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    var package_name: ?[]const u8 = null;
    var force_formula = false;
    var force_cask = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--formula") or std.mem.eql(u8, arg, "--formulae")) {
            force_formula = true;
        } else if (std.mem.eql(u8, arg, "--cask") or std.mem.eql(u8, arg, "--casks")) {
            force_cask = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (package_name == null) package_name = arg;
        }
    }

    // No package name: open Homebrew's homepage.
    if (package_name == null) {
        openUrl(allocator, "https://brew.sh");
        return;
    }

    const the_name = package_name.?;

    // Try formula index first (unless --cask was specified).
    if (!force_cask) {
        if (tryFormulaHome(allocator, the_name, config)) return;
    }

    // Try cask index (unless --formula was specified).
    if (!force_formula) {
        if (tryCaskHome(allocator, the_name, config)) return;
    }

    // Nothing found: error with suggestions.
    var idx = Index.loadOrBuild(allocator, config.cache) catch {
        const err_out = Output.initErr(config.no_color);
        err_out.err("No available formula or cask with the name \"{s}\".", .{the_name});
        std.process.exit(1);
    };

    const err_out = Output.initErr(config.no_color);
    err_out.err("No available formula or cask with the name \"{s}\".", .{the_name});
    const similar = fuzzy.findSimilar(&idx, allocator, the_name, 3, 3) catch &.{};
    defer if (similar.len > 0) allocator.free(similar);
    if (similar.len > 0) {
        err_out.print("Did you mean?\n", .{});
        for (similar) |s| err_out.print("  {s}\n", .{s});
    }
    std.process.exit(1);
}

/// Try to open the homepage for a formula. Returns true if found.
fn tryFormulaHome(allocator: Allocator, name: []const u8, config: Config) bool {
    var idx = Index.loadOrBuild(allocator, config.cache) catch return false;
    const entry = idx.lookup(name) orelse return false;
    const homepage = idx.getString(entry.homepage_offset);
    if (homepage.len == 0) return false;
    openUrl(allocator, homepage);
    return true;
}

/// Try to open the homepage for a cask. Returns true if found.
fn tryCaskHome(allocator: Allocator, name: []const u8, config: Config) bool {
    var cask_idx = CaskIndex.loadOrBuild(allocator, config.cache) catch return false;
    const entry = cask_idx.lookup(name) orelse return false;
    const homepage = cask_idx.getString(entry.homepage_offset);
    if (homepage.len == 0) return false;
    openUrl(allocator, homepage);
    return true;
}

/// Open a URL in the default browser using the platform's open command.
fn openUrl(allocator: Allocator, url: []const u8) void {
    const open_cmd = if (builtin.os.tag == .linux) "xdg-open" else "open";
    const argv = [_][]const u8{ open_cmd, url };
    var child = std.process.Child.init(&argv, allocator);
    _ = child.spawnAndWait() catch {
        var buf: [4096]u8 = undefined;
        var w = std.fs.File.stderr().writer(&buf);
        const stderr = &w.interface;
        stderr.print("bru: error: failed to open {s}\n", .{url}) catch {};
        stderr.flush() catch {};
        return;
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "homeCmd compiles and has correct signature" {
    const handler: @import("../dispatch.zig").CommandFn = homeCmd;
    _ = handler;
}

test "openUrl compiles" {
    // Dead-code test: verify it compiles. Cannot call since it spawns a process.
    if (false) {
        openUrl(std.testing.allocator, "https://example.com");
    }
}
