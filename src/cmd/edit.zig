const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const Index = @import("../index.zig").Index;
const cask_index_mod = @import("../cask_index.zig");
const CaskIndex = cask_index_mod.CaskIndex;
const Output = @import("../output.zig").Output;
const fuzzy = @import("../fuzzy.zig");
const log = @import("log.zig");

/// Open a formula or cask source file in an editor, or open the Homebrew
/// repository directory.
///
/// Usage: bru edit [formula|cask]
///
/// With no arguments, opens the Homebrew repository in an editor.
/// With a formula or cask name, opens that package's source `.rb` file.
pub fn editCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
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

    // No package name: open the Homebrew repository directory in the editor.
    if (package_name == null) {
        execEditor(allocator, config.repository);
    }

    const the_name = package_name.?;

    // Try formula index first (unless --cask was specified).
    if (!force_cask) {
        if (tryFormulaEdit(allocator, the_name, config)) return;
    }

    // Try cask index (unless --formula was specified).
    if (!force_formula) {
        if (tryCaskEdit(allocator, the_name, config)) return;
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

/// Try to open the source file for a formula in an editor. Returns true if
/// found (or does not return if execve succeeds).
fn tryFormulaEdit(allocator: Allocator, name: []const u8, config: Config) bool {
    var idx = Index.loadOrBuild(allocator, config.cache) catch return false;
    const entry = idx.lookup(name) orelse return false;
    const tap = idx.getString(entry.tap_offset);
    const formula_name = idx.getString(entry.name_offset);
    if (tap.len == 0) return false;

    const slash = std.mem.indexOfScalar(u8, tap, '/') orelse return false;
    if (slash == 0 or slash + 1 >= tap.len) return false;
    const org = tap[0..slash];
    const repo = tap[slash + 1 ..];

    // Build tap path: {repository}/Library/Taps/{org}/homebrew-{repo}
    var tap_path_buf: [1024]u8 = undefined;
    const tap_path = std.fmt.bufPrint(&tap_path_buf, "{s}/Library/Taps/{s}/homebrew-{s}", .{ config.repository, org, repo }) catch return false;

    // Build formula file path using the canonical name from the index.
    var file_path_buf: [512]u8 = undefined;
    const rel_path = log.buildFormulaFilePath(&file_path_buf, org, repo, formula_name) orelse return false;

    // Build absolute path: {tap_path}/{rel_path}
    var abs_path_buf: [2048]u8 = undefined;
    const abs_path = std.fmt.bufPrint(&abs_path_buf, "{s}/{s}", .{ tap_path, rel_path }) catch return false;

    // Verify the file exists on disk.
    std.fs.accessAbsolute(abs_path, .{}) catch {
        const err_out = Output.initErr(config.no_color);
        err_out.err("No local source file for \"{s}\".", .{name});
        err_out.print("Run 'brew tap {s}' to clone the repository.\n", .{tap});
        std.process.exit(1);
    };

    execEditor(allocator, abs_path);
}

/// Try to open the source file for a cask in an editor. Returns true if
/// found (or does not return if execve succeeds).
fn tryCaskEdit(allocator: Allocator, name: []const u8, config: Config) bool {
    var cask_idx = CaskIndex.loadOrBuild(allocator, config.cache) catch return false;
    const entry = cask_idx.lookup(name) orelse return false;
    const token = cask_idx.getString(entry.token_offset);

    // Cask index doesn't store tap; hardcode to homebrew/cask.
    const org = "homebrew";
    const repo = "cask";

    // Build tap path: {repository}/Library/Taps/homebrew/homebrew-cask
    var tap_path_buf: [1024]u8 = undefined;
    const tap_path = std.fmt.bufPrint(&tap_path_buf, "{s}/Library/Taps/{s}/homebrew-{s}", .{ config.repository, org, repo }) catch return false;

    // Build cask file path using the canonical token from the index.
    var file_path_buf: [512]u8 = undefined;
    const rel_path = log.buildCaskFilePath(&file_path_buf, org, repo, token) orelse return false;

    // Build absolute path: {tap_path}/{rel_path}
    var abs_path_buf: [2048]u8 = undefined;
    const abs_path = std.fmt.bufPrint(&abs_path_buf, "{s}/{s}", .{ tap_path, rel_path }) catch return false;

    // Verify the file exists on disk.
    std.fs.accessAbsolute(abs_path, .{}) catch {
        const err_out = Output.initErr(config.no_color);
        err_out.err("No local source file for \"{s}\".", .{name});
        err_out.print("Run 'brew tap homebrew/cask' to clone the repository.\n", .{});
        std.process.exit(1);
    };

    execEditor(allocator, abs_path);
}

/// Resolve the user's preferred editor from environment variables.
/// Checks $HOMEBREW_EDITOR, $EDITOR, $VISUAL, then falls back to a
/// platform default.
fn resolveEditor() []const u8 {
    if (std.posix.getenv("HOMEBREW_EDITOR")) |e| if (e.len > 0) return e;
    if (std.posix.getenv("EDITOR")) |e| if (e.len > 0) return e;
    if (std.posix.getenv("VISUAL")) |e| if (e.len > 0) return e;

    return if (builtin.os.tag == .linux) "editor" else "/usr/bin/nano";
}

/// Replace the current process with the editor, opening the given path.
/// This function does not return on success.
fn execEditor(allocator: Allocator, path: []const u8) noreturn {
    const editor = resolveEditor();
    const argv = allocator.alloc([]const u8, 2) catch {
        printStderr("bru: error: out of memory\n");
        std.process.exit(1);
    };
    argv[0] = editor;
    argv[1] = path;

    const err = std.process.execve(allocator, argv, null);

    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    const stderr = &w.interface;
    stderr.print("bru: error: failed to exec editor '{s}': {}\n", .{ editor, err }) catch {};
    stderr.flush() catch {};
    std.process.exit(1);
}

/// Write a string to stderr. Best-effort; ignores write errors.
fn printStderr(msg: []const u8) void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    const stderr = &w.interface;
    stderr.writeAll(msg) catch {};
    stderr.flush() catch {};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "editCmd compiles and has correct signature" {
    const handler: @import("../dispatch.zig").CommandFn = editCmd;
    _ = handler;
}

test "resolveEditor returns a non-empty string" {
    const editor = resolveEditor();
    try std.testing.expect(editor.len > 0);
}

test "execEditor compiles" {
    // Dead-code test: verify it compiles. Cannot call since it's noreturn.
    if (false) {
        execEditor(std.testing.allocator, "/tmp/test.rb");
    }
}
