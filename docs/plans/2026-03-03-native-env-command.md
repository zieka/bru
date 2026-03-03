# Native `env` Command Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement a native `env` command that prints Homebrew's build environment variables, matching `brew --env` output.

**Architecture:** Single new file `src/cmd/env.zig` with output writers per format (bash/fish/csh/plain). Detects SDK path via `xcrun`, CPU count via OS-specific syscall, and git path via `which`. Wired into dispatch table and help system.

**Tech Stack:** Zig, std.posix, std.process.Child for external commands (xcrun, sysctl)

---

### Task 1: Create env.zig with smoke test and flag parsing

**Files:**
- Create: `src/cmd/env.zig`

**Step 1: Write the env.zig file with flag parsing and smoke test**

Create `src/cmd/env.zig` with the command signature, flag parsing for `--plain` and `--shell=SHELL`, and a smoke test:

```zig
const std = @import("std");
const builtin = @import("builtin");
const Config = @import("../config.zig").Config;

/// Output format for the env command.
const OutputFormat = enum { bash, fish, csh, plain };

/// Parse args to determine output format.
///
/// Priority: --plain wins, then --shell=SHELL, then default (bash).
fn parseFormat(args: []const []const u8) OutputFormat {
    var plain = false;
    var shell: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--plain")) {
            plain = true;
        } else if (std.mem.startsWith(u8, arg, "--shell=")) {
            shell = arg["--shell=".len..];
        }
    }

    if (plain) return .plain;

    if (shell) |s| {
        if (std.mem.eql(u8, s, "fish")) return .fish;
        if (std.mem.eql(u8, s, "csh") or std.mem.eql(u8, s, "tcsh")) return .csh;
        // bash, zsh, sh, or anything else -> bash format
        return .bash;
    }

    return .bash;
}

/// Print Homebrew build environment variables.
pub fn envCmd(allocator: std.mem.Allocator, args: []const []const u8, config: Config) anyerror!void {
    _ = allocator;
    _ = args;
    _ = config;
    // Stub — will be implemented in Task 2
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "envCmd compiles and has correct signature" {
    const handler: @import("../dispatch.zig").CommandFn = envCmd;
    _ = handler;
}

test "parseFormat defaults to bash" {
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

test "parseFormat recognizes --shell=tcsh as csh" {
    const args = &[_][]const u8{"--shell=tcsh"};
    try std.testing.expectEqual(OutputFormat.csh, parseFormat(args));
}

test "parseFormat --shell=zsh maps to bash format" {
    const args = &[_][]const u8{"--shell=zsh"};
    try std.testing.expectEqual(OutputFormat.bash, parseFormat(args));
}

test "parseFormat --plain takes priority over --shell" {
    const args = &[_][]const u8{ "--shell=fish", "--plain" };
    try std.testing.expectEqual(OutputFormat.plain, parseFormat(args));
}
```

**Step 2: Run tests to verify they pass**

Run: `cd /Users/kylescully/.sidequest/worktrees/c1e18902-2292-479e-9f9c-5fb4f5233852 && zig build test 2>&1 | tail -5`
Expected: All tests pass (including the new ones)

**Step 3: Commit**

```bash
git add src/cmd/env.zig
git commit -m "feat(env): add env.zig with flag parsing and smoke test"
```

---

### Task 2: Implement environment variable detection helpers

**Files:**
- Modify: `src/cmd/env.zig`

**Step 1: Add helper functions for detecting build environment values**

Add these helpers to `env.zig` (after `parseFormat`, before `envCmd`):

```zig
/// Detect the number of CPUs available for parallel builds.
fn getCpuCount() u16 {
    return std.Thread.getCpuCount() catch 1;
}

/// Run an external command and return its trimmed stdout.
/// Returns null if the command fails. Caller must free the result.
fn runCmd(allocator: std.mem.Allocator, argv: []const []const u8) ?[]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    }) catch return null;

    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    switch (result.term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }

    const trimmed = std.mem.trimRight(u8, result.stdout, &.{ '\n', '\r', ' ', '\t' });
    if (trimmed.len == 0) return null;

    return allocator.dupe(u8, trimmed) catch null;
}

/// Detect the macOS SDK root path via `xcrun --show-sdk-path`.
/// Returns null on non-macOS or if xcrun fails.
fn getSdkRoot(allocator: std.mem.Allocator) ?[]const u8 {
    if (comptime builtin.os.tag != .macos) return null;
    return runCmd(allocator, &.{ "xcrun", "--show-sdk-path" });
}

/// Get the macOS major version number from the ProductVersion.
/// Returns null on non-macOS or if detection fails.
fn getMacOSMajorVersion(allocator: std.mem.Allocator) ?[]const u8 {
    if (comptime builtin.os.tag != .macos) return null;
    const full_version = runCmd(allocator, &.{ "sw_vers", "-productVersion" }) orelse return null;
    defer allocator.free(full_version);
    // Extract major version (e.g. "15" from "15.3.1")
    const dot_pos = std.mem.indexOfScalar(u8, full_version, '.') orelse full_version.len;
    return allocator.dupe(u8, full_version[0..dot_pos]) catch null;
}
```

**Step 2: Add tests for the helpers**

```zig
test "getCpuCount returns at least 1" {
    const count = getCpuCount();
    try std.testing.expect(count >= 1);
}

test "getSdkRoot returns a path on macOS" {
    if (comptime builtin.os.tag != .macos) return;
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_instance.deinit();
    const allocator = gpa_instance.allocator();

    const sdk = getSdkRoot(allocator);
    defer if (sdk) |s| allocator.free(s);
    try std.testing.expect(sdk != null);
    try std.testing.expect(std.mem.startsWith(u8, sdk.?, "/"));
}

test "getMacOSMajorVersion returns a number string on macOS" {
    if (comptime builtin.os.tag != .macos) return;
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_instance.deinit();
    const allocator = gpa_instance.allocator();

    const version = getMacOSMajorVersion(allocator);
    defer if (version) |v| allocator.free(v);
    try std.testing.expect(version != null);
    try std.testing.expect(version.?.len > 0);
    // Should be a number
    for (version.?) |c| {
        try std.testing.expect(c >= '0' and c <= '9');
    }
}
```

**Step 3: Run tests**

Run: `cd /Users/kylescully/.sidequest/worktrees/c1e18902-2292-479e-9f9c-5fb4f5233852 && zig build test 2>&1 | tail -5`
Expected: All tests pass

**Step 4: Commit**

```bash
git add src/cmd/env.zig
git commit -m "feat(env): add build environment detection helpers"
```

---

### Task 3: Implement output writers for all four formats

**Files:**
- Modify: `src/cmd/env.zig`

**Step 1: Add the per-format writer functions**

Add these writer functions. They take a writer interface and all the computed values:

```zig
/// Write bash/zsh-format output: export KEY="VALUE"
fn writeBash(writer: anytype, env: EnvVars) !void {
    try writer.print(
        \\export CC="clang"
        \\export CXX="clang++"
        \\export OBJC="clang"
        \\export OBJCXX="clang++"
        \\export HOMEBREW_CC="clang"
        \\export HOMEBREW_CXX="clang++"
        \\export MAKEFLAGS="-j{d}"
        \\export CMAKE_PREFIX_PATH="{s}"
        \\
    , .{ env.cpu_count, env.prefix });
    if (env.cmake_include_path) |p| try writer.print("export CMAKE_INCLUDE_PATH=\"{s}\"\n", .{p});
    if (env.cmake_library_path) |p| try writer.print("export CMAKE_LIBRARY_PATH=\"{s}\"\n", .{p});
    try writer.print("export PKG_CONFIG_LIBDIR=\"{s}\"\n", .{env.pkg_config_libdir});
    try writer.print(
        \\export HOMEBREW_MAKE_JOBS="{d}"
        \\export HOMEBREW_GIT="git"
        \\
    , .{env.cpu_count});
    if (env.sdkroot) |s| try writer.print("export HOMEBREW_SDKROOT=\"{s}\"\n", .{s});
    try writer.print(
        \\export ACLOCAL_PATH="{s}/share/aclocal"
        \\export PATH="{s}/Library/Homebrew/shims/mac/super:/usr/bin:/bin:/usr/sbin:/sbin"
        \\
    , .{ env.prefix, env.prefix });
}

/// Write fish-format output: set -gx KEY "VALUE"
fn writeFish(writer: anytype, env: EnvVars) !void {
    try writer.print(
        \\set -gx CC "clang"
        \\set -gx CXX "clang++"
        \\set -gx OBJC "clang"
        \\set -gx OBJCXX "clang++"
        \\set -gx HOMEBREW_CC "clang"
        \\set -gx HOMEBREW_CXX "clang++"
        \\set -gx MAKEFLAGS "-j{d}"
        \\set -gx CMAKE_PREFIX_PATH "{s}"
        \\
    , .{ env.cpu_count, env.prefix });
    if (env.cmake_include_path) |p| try writer.print("set -gx CMAKE_INCLUDE_PATH \"{s}\"\n", .{p});
    if (env.cmake_library_path) |p| try writer.print("set -gx CMAKE_LIBRARY_PATH \"{s}\"\n", .{p});
    try writer.print("set -gx PKG_CONFIG_LIBDIR \"{s}\"\n", .{env.pkg_config_libdir});
    try writer.print(
        \\set -gx HOMEBREW_MAKE_JOBS "{d}"
        \\set -gx HOMEBREW_GIT "git"
        \\
    , .{env.cpu_count});
    if (env.sdkroot) |s| try writer.print("set -gx HOMEBREW_SDKROOT \"{s}\"\n", .{s});
    try writer.print(
        \\set -gx ACLOCAL_PATH "{s}/share/aclocal"
        \\set -gx PATH "{s}/Library/Homebrew/shims/mac/super:/usr/bin:/bin:/usr/sbin:/sbin"
        \\
    , .{ env.prefix, env.prefix });
}

/// Write csh/tcsh-format output: setenv KEY VALUE;
fn writeCsh(writer: anytype, env: EnvVars) !void {
    try writer.print(
        \\setenv CC clang;
        \\setenv CXX clang++;
        \\setenv OBJC clang;
        \\setenv OBJCXX clang++;
        \\setenv HOMEBREW_CC clang;
        \\setenv HOMEBREW_CXX clang++;
        \\setenv MAKEFLAGS -j{d};
        \\setenv CMAKE_PREFIX_PATH {s};
        \\
    , .{ env.cpu_count, env.prefix });
    if (env.cmake_include_path) |p| try writer.print("setenv CMAKE_INCLUDE_PATH {s};\n", .{p});
    if (env.cmake_library_path) |p| try writer.print("setenv CMAKE_LIBRARY_PATH {s};\n", .{p});
    try writer.print("setenv PKG_CONFIG_LIBDIR {s};\n", .{env.pkg_config_libdir});
    try writer.print(
        \\setenv HOMEBREW_MAKE_JOBS {d};
        \\setenv HOMEBREW_GIT git;
        \\
    , .{env.cpu_count});
    if (env.sdkroot) |s| try writer.print("setenv HOMEBREW_SDKROOT {s};\n", .{s});
    try writer.print(
        \\setenv ACLOCAL_PATH {s}/share/aclocal;
        \\setenv PATH {s}/Library/Homebrew/shims/mac/super:/usr/bin:/bin:/usr/sbin:/sbin;
        \\
    , .{ env.prefix, env.prefix });
}

/// Write plain-format output: KEY: VALUE (no CC/CXX/OBJC/OBJCXX)
fn writePlain(writer: anytype, env: EnvVars) !void {
    try writer.print(
        \\HOMEBREW_CC: clang
        \\HOMEBREW_CXX: clang++
        \\MAKEFLAGS: -j{d}
        \\CMAKE_PREFIX_PATH: {s}
        \\
    , .{ env.cpu_count, env.prefix });
    if (env.cmake_include_path) |p| try writer.print("CMAKE_INCLUDE_PATH: {s}\n", .{p});
    if (env.cmake_library_path) |p| try writer.print("CMAKE_LIBRARY_PATH: {s}\n", .{p});
    try writer.print("PKG_CONFIG_LIBDIR: {s}\n", .{env.pkg_config_libdir});
    try writer.print(
        \\HOMEBREW_MAKE_JOBS: {d}
        \\HOMEBREW_GIT: git
        \\
    , .{env.cpu_count});
    if (env.sdkroot) |s| try writer.print("HOMEBREW_SDKROOT: {s}\n", .{s});
    try writer.print(
        \\ACLOCAL_PATH: {s}/share/aclocal
        \\PATH: {s}/Library/Homebrew/shims/mac/super:/usr/bin:/bin:/usr/sbin:/sbin
        \\
    , .{ env.prefix, env.prefix });
}
```

Also add the `EnvVars` struct to hold computed values:

```zig
/// Collected environment values for output.
const EnvVars = struct {
    prefix: []const u8,
    cpu_count: u16,
    sdkroot: ?[]const u8,
    cmake_include_path: ?[]const u8,
    cmake_library_path: ?[]const u8,
    pkg_config_libdir: []const u8,
};
```

**Step 2: Add tests for each writer**

```zig
test "writeBash produces correct output" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    const env = EnvVars{
        .prefix = "/test/prefix",
        .cpu_count = 8,
        .sdkroot = "/test/sdk",
        .cmake_include_path = "/test/sdk/include",
        .cmake_library_path = "/test/sdk/lib",
        .pkg_config_libdir = "/usr/lib/pkgconfig:/test/prefix/Library/Homebrew/os/mac/pkgconfig/15",
    };

    try writeBash(writer, env);
    const output = fbs.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, output, "export CC=\"clang\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "export MAKEFLAGS=\"-j8\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "export CMAKE_PREFIX_PATH=\"/test/prefix\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "export HOMEBREW_SDKROOT=\"/test/sdk\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "export HOMEBREW_MAKE_JOBS=\"8\"") != null);
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
        .pkg_config_libdir = "/usr/lib/pkgconfig",
    };

    try writePlain(writer, env);
    const output = fbs.getWritten();

    // Plain format should NOT contain bare CC/CXX/OBJC/OBJCXX lines
    try std.testing.expect(std.mem.indexOf(u8, output, "CC: clang") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "CXX: clang") == null);
    // But SHOULD contain HOMEBREW_CC/HOMEBREW_CXX
    try std.testing.expect(std.mem.indexOf(u8, output, "HOMEBREW_CC: clang") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "HOMEBREW_CXX: clang++") != null);
    // Should NOT have HOMEBREW_SDKROOT when null
    try std.testing.expect(std.mem.indexOf(u8, output, "HOMEBREW_SDKROOT") == null);
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
        .pkg_config_libdir = "/usr/lib/pkgconfig",
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
        .pkg_config_libdir = "/usr/lib/pkgconfig",
    };

    try writeCsh(writer, env);
    const output = fbs.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, output, "setenv CC clang;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "setenv HOMEBREW_SDKROOT /test/sdk;") != null);
}
```

**Step 3: Run tests**

Run: `cd /Users/kylescully/.sidequest/worktrees/c1e18902-2292-479e-9f9c-5fb4f5233852 && zig build test 2>&1 | tail -5`
Expected: All tests pass

**Step 4: Commit**

```bash
git add src/cmd/env.zig
git commit -m "feat(env): add output writers for bash, fish, csh, and plain formats"
```

---

### Task 4: Implement envCmd body — wire detection + output together

**Files:**
- Modify: `src/cmd/env.zig`

**Step 1: Implement the envCmd function body**

Replace the stub `envCmd` with the full implementation:

```zig
/// Print Homebrew build environment variables.
pub fn envCmd(allocator: std.mem.Allocator, args: []const []const u8, config: Config) anyerror!void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const stdout = &w.interface;

    const format = parseFormat(args);
    const cpu_count = getCpuCount();

    // Detect SDK root and compute derived paths (macOS only)
    const sdkroot = getSdkRoot(allocator);
    defer if (sdkroot) |s| allocator.free(s);

    const macos_ver = getMacOSMajorVersion(allocator);
    defer if (macos_ver) |v| allocator.free(v);

    // Compute cmake_include_path and cmake_library_path from SDK root
    var cmake_include_buf: [512]u8 = undefined;
    var cmake_library_buf: [512]u8 = undefined;
    const cmake_include_path: ?[]const u8 = if (sdkroot) |sdk|
        std.fmt.bufPrint(&cmake_include_buf, "{s}/System/Library/Frameworks/OpenGL.framework/Versions/Current/Headers", .{sdk}) catch null
    else
        null;
    const cmake_library_path: ?[]const u8 = if (sdkroot) |sdk|
        std.fmt.bufPrint(&cmake_library_buf, "{s}/System/Library/Frameworks/OpenGL.framework/Versions/Current/Libraries", .{sdk}) catch null
    else
        null;

    // Compute PKG_CONFIG_LIBDIR
    var pkg_buf: [512]u8 = undefined;
    const pkg_config_libdir: []const u8 = if (macos_ver) |ver|
        std.fmt.bufPrint(&pkg_buf, "/usr/lib/pkgconfig:{s}/Library/Homebrew/os/mac/pkgconfig/{s}", .{ config.prefix, ver }) catch "/usr/lib/pkgconfig"
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
```

**Step 2: Run tests**

Run: `cd /Users/kylescully/.sidequest/worktrees/c1e18902-2292-479e-9f9c-5fb4f5233852 && zig build test 2>&1 | tail -5`
Expected: All tests pass

**Step 3: Commit**

```bash
git add src/cmd/env.zig
git commit -m "feat(env): implement envCmd with full build environment detection"
```

---

### Task 5: Wire into dispatch, help, and main

**Files:**
- Modify: `src/dispatch.zig` (add import + dispatch entry)
- Modify: `src/help.zig` (add help text + general help entry)
- Modify: `src/main.zig` (add test import)

**Step 1: Add import and dispatch entry in dispatch.zig**

In `src/dispatch.zig`, add the import at line 29 (after `const formulae`):

```zig
const env_cmd = @import("cmd/env.zig");
```

Add to the `native_commands` table (after the formulae entry at line 87):

```zig
.{ .name = "env", .handler = env_cmd.envCmd },
```

**Step 2: Add help text in help.zig**

In `src/help.zig`, add to the `entries` in `getCommandHelp` (after the `shellenv` entry around line 292):

```zig
.{ "env",
    \\Usage: bru env [--plain] [--shell=SHELL]
    \\
    \\Print Homebrew's build environment variables.
    \\
    \\Options:
    \\  --plain        Print as "KEY: VALUE" (one per line)
    \\  --shell=SHELL  Print for a specific shell (bash/fish/csh)
    \\
    \\The default output uses bash export syntax.
    \\Alias: --env
    \\
},
```

Also update the general help text — add `env` to the "Environment commands" section (after the `shellenv` line around line 49):

```
\\  env        Print build environment variables
```

**Step 3: Add test import in main.zig**

In `src/main.zig`, add to the test block (after the shellenv import at line 109):

```zig
_ = @import("cmd/env.zig");
```

**Step 4: Add help test in help.zig**

In `src/help.zig`, add `"env"` to the `getCommandHelp returns help for known commands` test (around line 343):

```zig
try std.testing.expect(getCommandHelp("env") != null);
```

**Step 5: Run tests**

Run: `cd /Users/kylescully/.sidequest/worktrees/c1e18902-2292-479e-9f9c-5fb4f5233852 && zig build test 2>&1 | tail -5`
Expected: All tests pass

**Step 6: Run a quick manual verification**

Run: `cd /Users/kylescully/.sidequest/worktrees/c1e18902-2292-479e-9f9c-5fb4f5233852 && zig build && ./zig-out/bin/bru env`
Expected: Output matching `brew --env` format

Run: `./zig-out/bin/bru env --plain`
Expected: Output in `KEY: VALUE` format

Run: `./zig-out/bin/bru --env`
Expected: Same as `bru env` (alias already wired in dispatch)

Run: `./zig-out/bin/bru env --help`
Expected: Help text for the env command

**Step 7: Commit**

```bash
git add src/dispatch.zig src/help.zig src/main.zig
git commit -m "feat(env): wire env command into dispatch, help, and main"
```

---

### Task 6: Final build and integration test

**Files:**
- None (verification only)

**Step 1: Full test suite**

Run: `cd /Users/kylescully/.sidequest/worktrees/c1e18902-2292-479e-9f9c-5fb4f5233852 && zig build test 2>&1`
Expected: All tests pass, no warnings

**Step 2: Build release**

Run: `cd /Users/kylescully/.sidequest/worktrees/c1e18902-2292-479e-9f9c-5fb4f5233852 && zig build -Doptimize=ReleaseFast 2>&1`
Expected: Clean build

**Step 3: Compare output with real brew**

Run: `diff <(./zig-out/bin/bru env) <(brew --env)` to compare outputs.
Expected: Output should be very similar. Minor differences in PATH or SDK paths are acceptable since real brew uses its own shim layer.

**Step 4: Commit if any fixes were needed, then done**
