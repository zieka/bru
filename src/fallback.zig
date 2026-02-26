const std = @import("std");

/// Known default locations for the brew binary, checked in order.
const known_brew_paths = [_][]const u8{
    "/opt/homebrew/bin/brew",
    "/usr/local/bin/brew",
    "/home/linuxbrew/.linuxbrew/bin/brew",
};

/// Locate the real Homebrew `brew` binary.
///
/// Resolution order:
/// 1. HOMEBREW_BREW_FILE environment variable (if set and non-empty).
/// 2. Well-known installation paths checked for executable access.
/// 3. Returns null if no brew binary can be found.
pub fn findBrewPath(allocator: std.mem.Allocator) ?[]const u8 {
    _ = allocator;

    // 1. Check HOMEBREW_BREW_FILE env var.
    if (std.posix.getenv("HOMEBREW_BREW_FILE")) |brew_file| {
        if (brew_file.len > 0) return brew_file;
    }

    // 2. Check known paths for executable access.
    for (&known_brew_paths) |path| {
        std.posix.access(path, std.posix.X_OK) catch continue;
        return path;
    }

    return null;
}

/// Replace the current process with the real brew binary, forwarding all
/// arguments. This function does not return on success; it only returns
/// (via exit) when brew cannot be found or execve fails.
pub fn execBrew(allocator: std.mem.Allocator, argv: []const []const u8) noreturn {
    const brew_path = findBrewPath(allocator) orelse {
        printStderr("bru: error: could not find a brew executable\n");
        std.process.exit(1);
    };

    // Build a new argv with brew_path replacing argv[0].
    const new_argv = allocator.alloc([]const u8, argv.len) catch {
        printStderr("bru: error: out of memory\n");
        std.process.exit(1);
    };

    new_argv[0] = brew_path;
    if (argv.len > 1) {
        @memcpy(new_argv[1..], argv[1..]);
    }

    // execve replaces the process on success; on failure it returns an error.
    const err = std.process.execve(allocator, new_argv, null);

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    stderr.print("bru: error: failed to exec brew: {}\n", .{err}) catch {};
    stderr.flush() catch {};
    std.process.exit(1);
}

/// Write a string to stderr. Best-effort; ignores write errors.
fn printStderr(msg: []const u8) void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    stderr.writeAll(msg) catch {};
    stderr.flush() catch {};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "findBrewPath finds brew on this system" {
    const path = findBrewPath(std.testing.allocator);

    // We expect brew to be installed on the machine running tests.
    try std.testing.expect(path != null);
    try std.testing.expect(std.mem.endsWith(u8, path.?, "brew"));
}
