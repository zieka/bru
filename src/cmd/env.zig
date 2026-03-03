const std = @import("std");
const builtin = @import("builtin");
const Config = @import("../config.zig").Config;

/// Output format for the `env` command.
pub const OutputFormat = enum { bash, fish, csh, plain };

/// Parse command arguments for `--plain` and `--shell=SHELL` flags.
///
/// Priority: `--plain` wins over `--shell`. For `--shell`, `fish` maps to
/// `.fish`, `csh`/`tcsh` map to `.csh`, everything else maps to `.bash`.
/// Default (no flags) is `.bash`.
pub fn parseFormat(args: []const []const u8) OutputFormat {
    var has_plain = false;
    var shell_format: ?OutputFormat = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--plain")) {
            has_plain = true;
        } else if (std.mem.startsWith(u8, arg, "--shell=")) {
            const shell = arg["--shell=".len..];
            if (std.mem.eql(u8, shell, "fish")) {
                shell_format = .fish;
            } else if (std.mem.eql(u8, shell, "csh") or std.mem.eql(u8, shell, "tcsh")) {
                shell_format = .csh;
            } else {
                shell_format = .bash;
            }
        }
    }

    if (has_plain) return .plain;
    if (shell_format) |fmt| return fmt;
    return .bash;
}

/// Return the number of CPUs available on this system (minimum 1).
fn getCpuCount() u16 {
    const count = std.Thread.getCpuCount() catch 1;
    return @intCast(@min(count, std.math.maxInt(u16)));
}

/// Run an external command and return its trimmed stdout, or null on failure.
/// Caller must free the returned slice with the same allocator.
fn runCmd(allocator: std.mem.Allocator, argv: []const []const u8) ?[]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    }) catch return null;

    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    // Check for successful exit.
    switch (result.term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }

    const trimmed = std.mem.trimRight(u8, result.stdout, &.{ '\n', '\r', ' ', '\t' });
    if (trimmed.len == 0) return null;

    return allocator.dupe(u8, trimmed) catch null;
}

/// Return the macOS SDK root path via `xcrun --show-sdk-path`, or null on
/// non-macOS platforms.  Caller must free the returned slice.
pub fn getSdkRoot(allocator: std.mem.Allocator) ?[]const u8 {
    if (comptime builtin.os.tag != .macos) return null;
    return runCmd(allocator, &.{ "xcrun", "--show-sdk-path" });
}

/// Return the macOS major version (e.g. "15") via `sw_vers -productVersion`,
/// or null on non-macOS platforms.  Caller must free the returned slice.
pub fn getMacOSMajorVersion(allocator: std.mem.Allocator) ?[]const u8 {
    if (comptime builtin.os.tag != .macos) return null;

    const full_version = runCmd(allocator, &.{ "sw_vers", "-productVersion" }) orelse return null;
    defer allocator.free(full_version);

    const dot_index = std.mem.indexOfScalar(u8, full_version, '.') orelse full_version.len;
    const major = full_version[0..dot_index];
    if (major.len == 0) return null;

    return allocator.dupe(u8, major) catch null;
}

/// Collected environment values for output.
const EnvVars = struct {
    prefix: []const u8,
    cpu_count: u16,
    sdkroot: ?[]const u8,
    cmake_include_path: ?[]const u8,
    cmake_library_path: ?[]const u8,
    pkg_config_libdir: []const u8,
};

/// Write environment variables in Bash format (`export KEY="VALUE"`).
fn writeBash(writer: anytype, env: EnvVars) !void {
    try writer.writeAll("export CC=\"clang\"\n");
    try writer.writeAll("export CXX=\"clang++\"\n");
    try writer.writeAll("export OBJC=\"clang\"\n");
    try writer.writeAll("export OBJCXX=\"clang++\"\n");
    try writer.writeAll("export HOMEBREW_CC=\"clang\"\n");
    try writer.writeAll("export HOMEBREW_CXX=\"clang++\"\n");
    try writer.print("export MAKEFLAGS=\"-j{d}\"\n", .{env.cpu_count});
    try writer.print("export CMAKE_PREFIX_PATH=\"{s}\"\n", .{env.prefix});
    if (env.cmake_include_path) |p| {
        try writer.print("export CMAKE_INCLUDE_PATH=\"{s}\"\n", .{p});
    }
    if (env.cmake_library_path) |p| {
        try writer.print("export CMAKE_LIBRARY_PATH=\"{s}\"\n", .{p});
    }
    try writer.print("export PKG_CONFIG_LIBDIR=\"{s}\"\n", .{env.pkg_config_libdir});
    try writer.print("export HOMEBREW_MAKE_JOBS=\"{d}\"\n", .{env.cpu_count});
    try writer.writeAll("export HOMEBREW_GIT=\"git\"\n");
    if (env.sdkroot) |sdk| {
        try writer.print("export HOMEBREW_SDKROOT=\"{s}\"\n", .{sdk});
    }
    try writer.print("export ACLOCAL_PATH=\"{s}/share/aclocal\"\n", .{env.prefix});
    try writer.print("export PATH=\"{s}/Library/Homebrew/shims/mac/super:/usr/bin:/bin:/usr/sbin:/sbin\"\n", .{env.prefix});
}

/// Write environment variables in Fish format (`set -gx KEY "VALUE"`).
fn writeFish(writer: anytype, env: EnvVars) !void {
    try writer.writeAll("set -gx CC \"clang\"\n");
    try writer.writeAll("set -gx CXX \"clang++\"\n");
    try writer.writeAll("set -gx OBJC \"clang\"\n");
    try writer.writeAll("set -gx OBJCXX \"clang++\"\n");
    try writer.writeAll("set -gx HOMEBREW_CC \"clang\"\n");
    try writer.writeAll("set -gx HOMEBREW_CXX \"clang++\"\n");
    try writer.print("set -gx MAKEFLAGS \"-j{d}\"\n", .{env.cpu_count});
    try writer.print("set -gx CMAKE_PREFIX_PATH \"{s}\"\n", .{env.prefix});
    if (env.cmake_include_path) |p| {
        try writer.print("set -gx CMAKE_INCLUDE_PATH \"{s}\"\n", .{p});
    }
    if (env.cmake_library_path) |p| {
        try writer.print("set -gx CMAKE_LIBRARY_PATH \"{s}\"\n", .{p});
    }
    try writer.print("set -gx PKG_CONFIG_LIBDIR \"{s}\"\n", .{env.pkg_config_libdir});
    try writer.print("set -gx HOMEBREW_MAKE_JOBS \"{d}\"\n", .{env.cpu_count});
    try writer.writeAll("set -gx HOMEBREW_GIT \"git\"\n");
    if (env.sdkroot) |sdk| {
        try writer.print("set -gx HOMEBREW_SDKROOT \"{s}\"\n", .{sdk});
    }
    try writer.print("set -gx ACLOCAL_PATH \"{s}/share/aclocal\"\n", .{env.prefix});
    try writer.print("set -gx PATH \"{s}/Library/Homebrew/shims/mac/super:/usr/bin:/bin:/usr/sbin:/sbin\"\n", .{env.prefix});
}

/// Write environment variables in C-shell format (`setenv KEY VALUE;`).
fn writeCsh(writer: anytype, env: EnvVars) !void {
    try writer.writeAll("setenv CC clang;\n");
    try writer.writeAll("setenv CXX clang++;\n");
    try writer.writeAll("setenv OBJC clang;\n");
    try writer.writeAll("setenv OBJCXX clang++;\n");
    try writer.writeAll("setenv HOMEBREW_CC clang;\n");
    try writer.writeAll("setenv HOMEBREW_CXX clang++;\n");
    try writer.print("setenv MAKEFLAGS -j{d};\n", .{env.cpu_count});
    try writer.print("setenv CMAKE_PREFIX_PATH {s};\n", .{env.prefix});
    if (env.cmake_include_path) |p| {
        try writer.print("setenv CMAKE_INCLUDE_PATH {s};\n", .{p});
    }
    if (env.cmake_library_path) |p| {
        try writer.print("setenv CMAKE_LIBRARY_PATH {s};\n", .{p});
    }
    try writer.print("setenv PKG_CONFIG_LIBDIR {s};\n", .{env.pkg_config_libdir});
    try writer.print("setenv HOMEBREW_MAKE_JOBS {d};\n", .{env.cpu_count});
    try writer.writeAll("setenv HOMEBREW_GIT git;\n");
    if (env.sdkroot) |sdk| {
        try writer.print("setenv HOMEBREW_SDKROOT {s};\n", .{sdk});
    }
    try writer.print("setenv ACLOCAL_PATH {s}/share/aclocal;\n", .{env.prefix});
    try writer.print("setenv PATH {s}/Library/Homebrew/shims/mac/super:/usr/bin:/bin:/usr/sbin:/sbin;\n", .{env.prefix});
}

/// Write environment variables in plain format (`KEY: VALUE`).
/// Note: plain format omits CC, CXX, OBJC, OBJCXX.
fn writePlain(writer: anytype, env: EnvVars) !void {
    try writer.writeAll("HOMEBREW_CC: clang\n");
    try writer.writeAll("HOMEBREW_CXX: clang++\n");
    try writer.print("MAKEFLAGS: -j{d}\n", .{env.cpu_count});
    try writer.print("CMAKE_PREFIX_PATH: {s}\n", .{env.prefix});
    if (env.cmake_include_path) |p| {
        try writer.print("CMAKE_INCLUDE_PATH: {s}\n", .{p});
    }
    if (env.cmake_library_path) |p| {
        try writer.print("CMAKE_LIBRARY_PATH: {s}\n", .{p});
    }
    try writer.print("PKG_CONFIG_LIBDIR: {s}\n", .{env.pkg_config_libdir});
    try writer.print("HOMEBREW_MAKE_JOBS: {d}\n", .{env.cpu_count});
    try writer.writeAll("HOMEBREW_GIT: git\n");
    if (env.sdkroot) |sdk| {
        try writer.print("HOMEBREW_SDKROOT: {s}\n", .{sdk});
    }
    try writer.print("ACLOCAL_PATH: {s}/share/aclocal\n", .{env.prefix});
    try writer.print("PATH: {s}/Library/Homebrew/shims/mac/super:/usr/bin:/bin:/usr/sbin:/sbin\n", .{env.prefix});
}

/// Print Homebrew environment variables.
pub fn envCmd(allocator: std.mem.Allocator, args: []const []const u8, config: Config) anyerror!void {
    var stdout_buffer: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &w.interface;

    const format = parseFormat(args);
    const cpu_count = getCpuCount();

    const sdkroot = getSdkRoot(allocator);
    defer if (sdkroot) |v| allocator.free(v);

    const macos_major_version = getMacOSMajorVersion(allocator);
    defer if (macos_major_version) |v| allocator.free(v);

    // Compute cmake_include_path from sdkroot.
    var cmake_include_buf: [512]u8 = undefined;
    const cmake_include_path: ?[]const u8 = if (sdkroot) |sdk|
        std.fmt.bufPrint(&cmake_include_buf, "{s}/System/Library/Frameworks/OpenGL.framework/Versions/Current/Headers", .{sdk}) catch null
    else
        null;

    // Compute cmake_library_path from sdkroot.
    var cmake_library_buf: [512]u8 = undefined;
    const cmake_library_path: ?[]const u8 = if (sdkroot) |sdk|
        std.fmt.bufPrint(&cmake_library_buf, "{s}/System/Library/Frameworks/OpenGL.framework/Versions/Current/Libraries", .{sdk}) catch null
    else
        null;

    // Compute pkg_config_libdir.
    var pkg_config_buf: [512]u8 = undefined;
    const pkg_config_libdir: []const u8 = if (macos_major_version) |ver|
        std.fmt.bufPrint(&pkg_config_buf, "/usr/lib/pkgconfig:{s}/Library/Homebrew/os/mac/pkgconfig/{s}", .{ config.prefix, ver }) catch "/usr/lib/pkgconfig"
    else
        "/usr/lib/pkgconfig";

    const env = EnvVars{
        .prefix = config.prefix,
        .cpu_count = cpu_count,
        .sdkroot = sdkroot,
        .cmake_include_path = cmake_include_path,
        .cmake_library_path = cmake_library_path,
        .pkg_config_libdir = pkg_config_libdir,
    };

    switch (format) {
        .bash => try writeBash(stdout, env),
        .fish => try writeFish(stdout, env),
        .csh => try writeCsh(stdout, env),
        .plain => try writePlain(stdout, env),
    }

    try stdout.flush();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "envCmd compiles and has correct signature" {
    const handler: @import("../dispatch.zig").CommandFn = envCmd;
    _ = handler;
}

test "parseFormat defaults to .bash" {
    const args = &[_][]const u8{};
    try std.testing.expectEqual(OutputFormat.bash, parseFormat(args));
}

test "parseFormat recognizes --plain" {
    const args = &[_][]const u8{"--plain"};
    try std.testing.expectEqual(OutputFormat.plain, parseFormat(args));
}

test "parseFormat recognizes --shell=fish" {
    const args = &[_][]const u8{"--shell=fish"};
    try std.testing.expectEqual(OutputFormat.fish, parseFormat(args));
}

test "parseFormat recognizes --shell=csh" {
    const args = &[_][]const u8{"--shell=csh"};
    try std.testing.expectEqual(OutputFormat.csh, parseFormat(args));
}

test "parseFormat recognizes --shell=tcsh as .csh" {
    const args = &[_][]const u8{"--shell=tcsh"};
    try std.testing.expectEqual(OutputFormat.csh, parseFormat(args));
}

test "parseFormat --shell=zsh maps to .bash" {
    const args = &[_][]const u8{"--shell=zsh"};
    try std.testing.expectEqual(OutputFormat.bash, parseFormat(args));
}

test "parseFormat --plain takes priority over --shell" {
    const args = &[_][]const u8{ "--shell=fish", "--plain" };
    try std.testing.expectEqual(OutputFormat.plain, parseFormat(args));
}

test "getCpuCount returns at least 1" {
    const count = getCpuCount();
    try std.testing.expect(count >= 1);
}

test "getSdkRoot returns a path starting with / on macOS" {
    if (comptime builtin.os.tag != .macos) return;

    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_instance.deinit();
    const allocator = gpa_instance.allocator();

    const sdk_root = getSdkRoot(allocator);
    defer if (sdk_root) |v| allocator.free(v);

    try std.testing.expect(sdk_root != null);
    try std.testing.expect(sdk_root.?.len > 0);
    try std.testing.expectEqual(@as(u8, '/'), sdk_root.?[0]);
}

test "getMacOSMajorVersion returns a numeric string on macOS" {
    if (comptime builtin.os.tag != .macos) return;

    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_instance.deinit();
    const allocator = gpa_instance.allocator();

    const major = getMacOSMajorVersion(allocator);
    defer if (major) |v| allocator.free(v);

    try std.testing.expect(major != null);
    try std.testing.expect(major.?.len > 0);

    // Every character should be a digit.
    for (major.?) |c| {
        try std.testing.expect(std.ascii.isDigit(c));
    }
}

test "writeBash produces correct output" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    const env = EnvVars{
        .prefix = "/test/prefix",
        .cpu_count = 8,
        .sdkroot = "/test/sdk",
        .cmake_include_path = "/test/prefix/include",
        .cmake_library_path = "/test/prefix/lib",
        .pkg_config_libdir = "/test/prefix/lib/pkgconfig",
    };

    try writeBash(writer, env);
    const output = fbs.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, output, "export CC=\"clang\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "export CXX=\"clang++\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "export OBJC=\"clang\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "export OBJCXX=\"clang++\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "export HOMEBREW_CC=\"clang\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "export HOMEBREW_CXX=\"clang++\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "export MAKEFLAGS=\"-j8\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "export CMAKE_PREFIX_PATH=\"/test/prefix\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "export CMAKE_INCLUDE_PATH=\"/test/prefix/include\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "export CMAKE_LIBRARY_PATH=\"/test/prefix/lib\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "export PKG_CONFIG_LIBDIR=\"/test/prefix/lib/pkgconfig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "export HOMEBREW_MAKE_JOBS=\"8\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "export HOMEBREW_GIT=\"git\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "export HOMEBREW_SDKROOT=\"/test/sdk\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "export ACLOCAL_PATH=\"/test/prefix/share/aclocal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "export PATH=\"/test/prefix/Library/Homebrew/shims/mac/super:/usr/bin:/bin:/usr/sbin:/sbin\"") != null);
}

test "writePlain omits CC/CXX/OBJC/OBJCXX" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    const env = EnvVars{
        .prefix = "/test/prefix",
        .cpu_count = 4,
        .sdkroot = null,
        .cmake_include_path = null,
        .cmake_library_path = null,
        .pkg_config_libdir = "/test/prefix/lib/pkgconfig",
    };

    try writePlain(writer, env);
    const output = fbs.getWritten();

    // Plain format should NOT have CC, CXX, OBJC, OBJCXX lines.
    // Use "\n" prefix to avoid matching inside HOMEBREW_CC/HOMEBREW_CXX.
    // The output starts with "HOMEBREW_CC:" so there is no bare "CC:" at the start either.
    try std.testing.expect(std.mem.indexOf(u8, output, "\nCC: clang") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\nCXX: clang++") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\nOBJC: clang") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\nOBJCXX: clang++") == null);
    // Also verify the output doesn't start with these.
    try std.testing.expect(!std.mem.startsWith(u8, output, "CC: "));
    try std.testing.expect(!std.mem.startsWith(u8, output, "CXX: "));
    try std.testing.expect(!std.mem.startsWith(u8, output, "OBJC: "));
    try std.testing.expect(!std.mem.startsWith(u8, output, "OBJCXX: "));

    // But should have HOMEBREW_CC.
    try std.testing.expect(std.mem.indexOf(u8, output, "HOMEBREW_CC: clang") != null);

    // Null sdkroot means no HOMEBREW_SDKROOT line.
    try std.testing.expect(std.mem.indexOf(u8, output, "HOMEBREW_SDKROOT") == null);

    // Null cmake paths means no CMAKE_INCLUDE_PATH or CMAKE_LIBRARY_PATH lines.
    try std.testing.expect(std.mem.indexOf(u8, output, "CMAKE_INCLUDE_PATH") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "CMAKE_LIBRARY_PATH") == null);
}

test "writeFish uses set -gx syntax" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    const env = EnvVars{
        .prefix = "/test/prefix",
        .cpu_count = 2,
        .sdkroot = null,
        .cmake_include_path = null,
        .cmake_library_path = null,
        .pkg_config_libdir = "/test/prefix/lib/pkgconfig",
    };

    try writeFish(writer, env);
    const output = fbs.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, output, "set -gx CC \"clang\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "set -gx MAKEFLAGS \"-j2\"") != null);
}

test "writeCsh uses setenv syntax with semicolons" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    const env = EnvVars{
        .prefix = "/test/prefix",
        .cpu_count = 4,
        .sdkroot = "/test/sdk",
        .cmake_include_path = null,
        .cmake_library_path = null,
        .pkg_config_libdir = "/test/prefix/lib/pkgconfig",
    };

    try writeCsh(writer, env);
    const output = fbs.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, output, "setenv CC clang;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "setenv HOMEBREW_SDKROOT /test/sdk;") != null);
}
