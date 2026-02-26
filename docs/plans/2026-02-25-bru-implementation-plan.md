# bru Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a working bru binary that handles Tier 1 read-only commands natively and delegates everything else to brew.

**Architecture:** Single Zig binary with comptime dispatch table. Config loaded from env vars. Binary index built from Homebrew's JSON API cache. Exec fallback to real brew for unimplemented commands.

**Tech Stack:** Zig 0.15.2, targeting macOS (aarch64 + x86_64)

**Reference:** `docs/plans/2026-02-25-bru-architecture-design.md`

---

## Phase 1: Foundation (Tasks 1–6)

### Task 1: Build System Scaffold

**Files:**
- Create: `build.zig`
- Create: `build.zig.zon`
- Create: `src/main.zig`

**Step 1: Create build.zig.zon**

```zig
.{
    .name = .@"bru",
    .version = .@"0.1.0",
    .fingerprint = .@"zig-placeholder-fingerprint",
    .minimum_zig_version = .@"0.15.0",
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

Note: After creating the file, run `zig build` once — Zig 0.15 will auto-replace the placeholder fingerprint with a real one.

**Step 2: Create build.zig**

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "bru",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run bru");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
```

**Step 3: Create src/main.zig**

```zig
const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("bru 0.1.0\n", .{});
}
```

**Step 4: Build and run**

Run: `zig build run`
Expected: `bru 0.1.0`

**Step 5: Run tests**

Run: `zig build test`
Expected: All tests passed (no tests yet, should succeed)

**Step 6: Commit**

```bash
git add build.zig build.zig.zon src/main.zig
git commit -m "feat: initial build system and hello world"
```

---

### Task 2: Config Module

**Files:**
- Create: `src/config.zig`
- Modify: `src/main.zig`

**Context:** Config resolves all Homebrew paths from environment variables with sensible defaults. This is needed by every command. Key env vars: `HOMEBREW_PREFIX`, `HOMEBREW_CELLAR`, `HOMEBREW_CACHE`, `HOMEBREW_BREW_FILE`, `HOMEBREW_NO_COLOR`, `HOMEBREW_NO_EMOJI`, `NO_COLOR`.

On macOS ARM: prefix defaults to `/opt/homebrew`. On macOS x86: `/usr/local`. Cellar is `{prefix}/Cellar`. Cache is `~/Library/Caches/Homebrew`.

**Step 1: Write failing test in src/config.zig**

Create `src/config.zig` with the Config struct and a test:

```zig
const std = @import("std");

pub const Config = struct {
    prefix: []const u8,
    cellar: []const u8,
    caskroom: []const u8,
    cache: []const u8,
    brew_file: ?[]const u8,
    no_color: bool,
    no_emoji: bool,
    verbose: bool,
    debug: bool,
    quiet: bool,

    pub fn load(allocator: std.mem.Allocator) !Config {
        const env = std.process.getEnvMap;
        _ = env;
        _ = allocator;
        unreachable;
    }
};

test "config defaults on arm64 macOS" {
    const config = try Config.load(std.testing.allocator);
    try std.testing.expectEqualStrings("/opt/homebrew", config.prefix);
    try std.testing.expectEqualStrings("/opt/homebrew/Cellar", config.cellar);
    try std.testing.expect(!config.no_color);
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL (unreachable reached)

**Step 3: Implement Config.load**

Replace the `load` function body with real implementation:

```zig
pub fn load(allocator: std.mem.Allocator) !Config {
    const env_map = std.process.getEnvMap;
    _ = env_map;

    const prefix = std.process.getEnvVarOwned(allocator, "HOMEBREW_PREFIX") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try defaultPrefix(allocator),
        else => return err,
    };

    const cellar = std.process.getEnvVarOwned(allocator, "HOMEBREW_CELLAR") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try std.fmt.allocPrint(allocator, "{s}/Cellar", .{prefix}),
        else => return err,
    };

    const caskroom = std.process.getEnvVarOwned(allocator, "HOMEBREW_CASKROOM") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try std.fmt.allocPrint(allocator, "{s}/Caskroom", .{prefix}),
        else => return err,
    };

    const cache = std.process.getEnvVarOwned(allocator, "HOMEBREW_CACHE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try defaultCache(allocator),
        else => return err,
    };

    const brew_file = std.process.getEnvVarOwned(allocator, "HOMEBREW_BREW_FILE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };

    const no_color = envBool("HOMEBREW_NO_COLOR") or envBool("NO_COLOR");
    const no_emoji = envBool("HOMEBREW_NO_EMOJI");

    return Config{
        .prefix = prefix,
        .cellar = cellar,
        .caskroom = caskroom,
        .cache = cache,
        .brew_file = brew_file,
        .no_color = no_color,
        .no_emoji = no_emoji,
        .verbose = false,
        .debug = false,
        .quiet = false,
    };
}

fn envBool(name: []const u8) bool {
    const val = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch return false;
    defer std.heap.page_allocator.free(val);
    return val.len > 0;
}

fn defaultPrefix(allocator: std.mem.Allocator) ![]const u8 {
    // ARM macOS uses /opt/homebrew, Intel uses /usr/local
    const builtin = @import("builtin");
    if (builtin.os.tag == .macos) {
        if (builtin.cpu.arch == .aarch64) {
            return allocator.dupe(u8, "/opt/homebrew");
        }
        return allocator.dupe(u8, "/usr/local");
    }
    // Linux default
    return allocator.dupe(u8, "/home/linuxbrew/.linuxbrew");
}

fn defaultCache(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return error.EnvironmentVariableNotFound;
    defer allocator.free(home);
    const builtin = @import("builtin");
    if (builtin.os.tag == .macos) {
        return std.fmt.allocPrint(allocator, "{s}/Library/Caches/Homebrew", .{home});
    }
    return std.fmt.allocPrint(allocator, "{s}/.cache/Homebrew", .{home});
}
```

**Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS

**Step 5: Wire config into main.zig**

Update `src/main.zig` to import config and load it:

```zig
const std = @import("std");
const Config = @import("config.zig").Config;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = try Config.load(allocator);
    _ = config;

    const stdout = std.io.getStdOut().writer();
    try stdout.print("bru 0.1.0\n", .{});
}

test {
    _ = @import("config.zig");
}
```

**Step 6: Build and run**

Run: `zig build run`
Expected: `bru 0.1.0`

**Step 7: Commit**

```bash
git add src/config.zig src/main.zig
git commit -m "feat: config module with env var loading and platform defaults"
```

---

### Task 3: Argument Parsing & Dispatch Table

**Files:**
- Create: `src/dispatch.zig`
- Modify: `src/main.zig`

**Context:** Dispatch parses argv into: global flags (`--verbose`, `--debug`, `--quiet`, `--help`, `--version`), a command name, and remaining args. Commands are looked up in a comptime-built map. Unknown commands trigger exec fallback to real brew.

**Step 1: Write failing test in src/dispatch.zig**

```zig
const std = @import("std");
const Config = @import("config.zig").Config;

pub const CommandError = error{
    UnknownCommand,
    ExecFallback,
};

pub const CommandFn = *const fn (
    allocator: std.mem.Allocator,
    args: []const []const u8,
    config: Config,
) anyerror!void;

pub const ParsedArgs = struct {
    command: ?[]const u8,
    command_args: []const []const u8,
    verbose: bool,
    debug: bool,
    quiet: bool,
    help: bool,
    version: bool,
};

pub fn parseArgs(argv: []const []const u8) ParsedArgs {
    _ = argv;
    unreachable;
}

pub fn getCommand(name: []const u8) ?CommandFn {
    _ = name;
    unreachable;
}

test "parseArgs extracts command and flags" {
    const argv = &[_][]const u8{ "bru", "--verbose", "list", "--formula" };
    const parsed = parseArgs(argv);
    try std.testing.expectEqualStrings("list", parsed.command.?);
    try std.testing.expect(parsed.verbose);
    try std.testing.expectEqual(@as(usize, 1), parsed.command_args.len);
    try std.testing.expectEqualStrings("--formula", parsed.command_args[0]);
}

test "parseArgs with --version flag" {
    const argv = &[_][]const u8{ "bru", "--version" };
    const parsed = parseArgs(argv);
    try std.testing.expect(parsed.version);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.command);
}

test "parseArgs no command" {
    const argv = &[_][]const u8{"bru"};
    const parsed = parseArgs(argv);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.command);
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL

**Step 3: Implement parseArgs**

```zig
pub fn parseArgs(argv: []const []const u8) ParsedArgs {
    var verbose = false;
    var debug = false;
    var quiet = false;
    var help = false;
    var version = false;
    var command: ?[]const u8 = null;
    var cmd_args_start: usize = argv.len;

    // Skip argv[0] (program name)
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (command != null) {
            // Everything after command name is command args
            cmd_args_start = i;
            break;
        }
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--debug") or std.mem.eql(u8, arg, "-d")) {
            debug = true;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            help = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            version = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            command = resolveAlias(arg);
            // Next args are command args
        } else {
            // Unknown global flag — treat as command start? No, pass through.
            // For now, anything starting with - before command is a global flag we skip
        }
    }

    return ParsedArgs{
        .command = command,
        .command_args = if (cmd_args_start < argv.len) argv[cmd_args_start..] else &.{},
        .verbose = verbose,
        .debug = debug,
        .quiet = quiet,
        .help = help,
        .version = version,
    };
}

fn resolveAlias(name: []const u8) []const u8 {
    const aliases = .{
        .{ "ls", "list" },
        .{ "rm", "uninstall" },
        .{ "remove", "uninstall" },
        .{ "dr", "doctor" },
        .{ "-S", "search" },
        .{ "ln", "link" },
        .{ "homepage", "home" },
        .{ "instal", "install" },
        .{ "uninstal", "uninstall" },
        .{ "post_install", "postinstall" },
        .{ "lc", "livecheck" },
        .{ "environment", "env" },
        .{ "--config", "config" },
        .{ "--env", "env" },
        .{ "--prefix", "__prefix" },
        .{ "--cellar", "__cellar" },
        .{ "--cache", "__cache" },
        .{ "--caskroom", "__caskroom" },
        .{ "--repository", "__repo" },
        .{ "--repo", "__repo" },
    };
    inline for (aliases) |pair| {
        if (std.mem.eql(u8, name, pair[0])) return pair[1];
    }
    return name;
}
```

**Step 4: Run tests to verify they pass**

Run: `zig build test`
Expected: PASS

**Step 5: Wire dispatch into main.zig**

Update main.zig to use parseArgs and handle --version:

```zig
const std = @import("std");
const Config = @import("config.zig").Config;
const dispatch = @import("dispatch.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = try Config.load(allocator);

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const parsed = dispatch.parseArgs(argv);

    const stdout = std.io.getStdOut().writer();

    if (parsed.version) {
        try stdout.print("bru 0.1.0\n", .{});
        return;
    }

    if (parsed.command == null) {
        try stdout.print("bru 0.1.0\n", .{});
        try stdout.print("Run 'bru --help' for usage.\n", .{});
        return;
    }

    // For now, just print what we'd do
    try stdout.print("command: {s}\n", .{parsed.command.?});
    _ = config;
}

test {
    _ = @import("config.zig");
    _ = @import("dispatch.zig");
}
```

**Step 6: Build and test**

Run: `zig build run -- --version`
Expected: `bru 0.1.0`

Run: `zig build run -- list`
Expected: `command: list`

Run: `zig build run -- ls`
Expected: `command: list` (alias resolved)

**Step 7: Commit**

```bash
git add src/dispatch.zig src/main.zig
git commit -m "feat: argument parsing with global flags and alias resolution"
```

---

### Task 4: Exec Fallback to Brew

**Files:**
- Create: `src/fallback.zig`
- Modify: `src/main.zig`

**Context:** When a command isn't natively implemented, bru must exec the real brew binary with the original argv. This is the safety net that makes bru a drop-in replacement from day one. Find brew via: `HOMEBREW_BREW_FILE` env var, then `which brew`, then known paths (`/opt/homebrew/bin/brew`, `/usr/local/bin/brew`).

**Step 1: Create src/fallback.zig with test**

```zig
const std = @import("std");

pub fn findBrewPath(allocator: std.mem.Allocator) !?[]const u8 {
    _ = allocator;
    unreachable;
}

test "findBrewPath finds brew on this system" {
    const path = try findBrewPath(std.testing.allocator);
    try std.testing.expect(path != null);
    if (path) |p| {
        defer std.testing.allocator.free(p);
        try std.testing.expect(std.mem.endsWith(u8, p, "brew"));
    }
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL

**Step 3: Implement findBrewPath and execBrew**

```zig
const std = @import("std");

pub fn findBrewPath(allocator: std.mem.Allocator) !?[]const u8 {
    // 1. Check HOMEBREW_BREW_FILE env var
    if (std.process.getEnvVarOwned(allocator, "HOMEBREW_BREW_FILE")) |path| {
        return path;
    } else |_| {}

    // 2. Check known paths
    const known_paths = [_][]const u8{
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
        "/home/linuxbrew/.linuxbrew/bin/brew",
    };
    for (known_paths) |path| {
        std.fs.accessAbsolute(path, .{}) catch continue;
        return try allocator.dupe(u8, path);
    }

    return null;
}

pub fn execBrew(allocator: std.mem.Allocator, argv: []const []const u8) !noreturn {
    const brew_path = try findBrewPath(allocator) orelse {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("bru: could not find brew. Set HOMEBREW_BREW_FILE or install Homebrew.\n", .{});
        std.process.exit(1);
    };

    // Build argv with brew_path replacing argv[0]
    var new_argv = try allocator.alloc([]const u8, argv.len);
    new_argv[0] = brew_path;
    for (argv[1..], 1..) |arg, i| {
        new_argv[i] = arg;
    }

    const err = std.process.execve(allocator, new_argv, null);
    _ = err;
    // execve only returns on error
    const stderr = std.io.getStdErr().writer();
    try stderr.print("bru: failed to exec brew at {s}\n", .{brew_path});
    std.process.exit(1);
}

test "findBrewPath finds brew on this system" {
    const path = try findBrewPath(std.testing.allocator);
    try std.testing.expect(path != null);
    if (path) |p| {
        defer std.testing.allocator.free(p);
        try std.testing.expect(std.mem.endsWith(u8, p, "brew"));
    }
}
```

**Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS

**Step 5: Wire fallback into main.zig**

In main.zig, when a command is not found in the native dispatch table, call `execBrew`:

```zig
const fallback = @import("fallback.zig");

// ... in main(), after parsing:
if (parsed.command) |cmd_name| {
    // TODO: Check native command table first (added in later tasks)
    _ = cmd_name;
    try fallback.execBrew(allocator, argv);
}
```

**Step 6: Build and test manually**

Run: `zig build run -- info bat`
Expected: Same output as `brew info bat` (because it exec's to brew)

**Step 7: Commit**

```bash
git add src/fallback.zig src/main.zig
git commit -m "feat: exec fallback to real brew for unimplemented commands"
```

---

### Task 5: Output Utilities

**Files:**
- Create: `src/output.zig`

**Context:** Brew uses ANSI colors for section headers (`==> ` in green/bold), errors (red), warnings (yellow). Respects `HOMEBREW_NO_COLOR`, `NO_COLOR`, and pipe detection (no color when stdout is not a tty). Many commands need these helpers.

**Step 1: Create src/output.zig with test**

```zig
const std = @import("std");

pub const Style = enum {
    bold,
    green,
    red,
    yellow,
    cyan,
    reset,
};

pub const Output = struct {
    writer: std.fs.File.Writer,
    use_color: bool,

    pub fn init(no_color: bool) Output {
        const stdout = std.io.getStdOut();
        return .{
            .writer = stdout.writer(),
            .use_color = !no_color and std.posix.isatty(stdout.handle),
        };
    }

    pub fn initErr(no_color: bool) Output {
        const stderr = std.io.getStdErr();
        return .{
            .writer = stderr.writer(),
            .use_color = !no_color and std.posix.isatty(stderr.handle),
        };
    }

    pub fn print(self: Output, comptime fmt: []const u8, args: anytype) !void {
        try self.writer.print(fmt, args);
    }

    pub fn section(self: Output, title: []const u8) !void {
        if (self.use_color) {
            try self.writer.print("\x1b[34m==>\x1b[0m \x1b[1m{s}\x1b[0m\n", .{title});
        } else {
            try self.writer.print("==> {s}\n", .{title});
        }
    }

    pub fn warn(self: Output, comptime fmt: []const u8, args: anytype) !void {
        if (self.use_color) {
            try self.writer.print("\x1b[33mWarning\x1b[0m: " ++ fmt ++ "\n", args);
        } else {
            try self.writer.print("Warning: " ++ fmt ++ "\n", args);
        }
    }

    pub fn err(self: Output, comptime fmt: []const u8, args: anytype) !void {
        const stderr_writer = std.io.getStdErr().writer();
        if (self.use_color) {
            try stderr_writer.print("\x1b[31mError\x1b[0m: " ++ fmt ++ "\n", args);
        } else {
            try stderr_writer.print("Error: " ++ fmt ++ "\n", args);
        }
    }
};

test "Output init respects no_color" {
    const out = Output.init(true);
    try std.testing.expect(!out.use_color);
}

test "Output section no color" {
    // Just verify it doesn't crash
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const out = Output{
        .writer = undefined, // Can't easily test file writer in unit tests
        .use_color = false,
    };
    _ = out;
    _ = fbs;
    // Basic smoke test — real testing happens in compat tests
}
```

**Step 2: Run tests**

Run: `zig build test`
Expected: PASS

**Step 3: Commit**

```bash
git add src/output.zig
git commit -m "feat: output utilities with ANSI color and section headers"
```

---

### Task 6: Version Comparison

**Files:**
- Create: `src/version.zig`

**Context:** Homebrew version strings follow `major.minor.patch` with optional `_revision` suffix. `PkgVersion` in brew is `{version}_{revision}`. Comparison: split on `.`, compare segments numerically where possible, lexically otherwise. Revision (after `_`) compared separately. This is needed by `outdated`, `info`, and `upgrade`.

**Step 1: Write failing tests**

```zig
const std = @import("std");

pub const PkgVersion = struct {
    version: []const u8,
    revision: u32,

    pub fn parse(s: []const u8) PkgVersion {
        _ = s;
        unreachable;
    }

    pub fn order(self: PkgVersion, other: PkgVersion) std.math.Order {
        _ = self;
        _ = other;
        unreachable;
    }

    pub fn format(self: PkgVersion, buf: []u8) []const u8 {
        _ = self;
        _ = buf;
        unreachable;
    }
};

test "parse simple version" {
    const v = PkgVersion.parse("1.2.3");
    try std.testing.expectEqualStrings("1.2.3", v.version);
    try std.testing.expectEqual(@as(u32, 0), v.revision);
}

test "parse version with revision" {
    const v = PkgVersion.parse("3.6.1_1");
    try std.testing.expectEqualStrings("3.6.1", v.version);
    try std.testing.expectEqual(@as(u32, 1), v.revision);
}

test "compare versions" {
    const a = PkgVersion.parse("1.2.3");
    const b = PkgVersion.parse("1.2.4");
    try std.testing.expectEqual(std.math.Order.lt, a.order(b));
}

test "compare versions with revision" {
    const a = PkgVersion.parse("1.2.3");
    const b = PkgVersion.parse("1.2.3_1");
    try std.testing.expectEqual(std.math.Order.lt, a.order(b));
}

test "equal versions" {
    const a = PkgVersion.parse("2.0.0");
    const b = PkgVersion.parse("2.0.0");
    try std.testing.expectEqual(std.math.Order.eq, a.order(b));
}

test "compare major difference" {
    const a = PkgVersion.parse("2.0.0");
    const b = PkgVersion.parse("10.0.0");
    try std.testing.expectEqual(std.math.Order.lt, a.order(b));
}

test "format version with revision" {
    const v = PkgVersion{ .version = "3.6.1", .revision = 1 };
    var buf: [64]u8 = undefined;
    const s = v.format(&buf);
    try std.testing.expectEqualStrings("3.6.1_1", s);
}

test "format version without revision" {
    const v = PkgVersion{ .version = "1.0.0", .revision = 0 };
    var buf: [64]u8 = undefined;
    const s = v.format(&buf);
    try std.testing.expectEqualStrings("1.0.0", s);
}
```

**Step 2: Run test to verify they fail**

Run: `zig build test`
Expected: FAIL

**Step 3: Implement PkgVersion**

```zig
pub const PkgVersion = struct {
    version: []const u8,
    revision: u32,

    pub fn parse(s: []const u8) PkgVersion {
        // Find last underscore followed by digits
        if (std.mem.lastIndexOfScalar(u8, s, '_')) |idx| {
            const rev_str = s[idx + 1 ..];
            if (std.fmt.parseInt(u32, rev_str, 10)) |rev| {
                return .{ .version = s[0..idx], .revision = rev };
            } else |_| {}
        }
        return .{ .version = s, .revision = 0 };
    }

    pub fn order(self: PkgVersion, other: PkgVersion) std.math.Order {
        const ver_cmp = compareVersionStrings(self.version, other.version);
        if (ver_cmp != .eq) return ver_cmp;
        return std.math.order(self.revision, other.revision);
    }

    pub fn format(self: PkgVersion, buf: []u8) []const u8 {
        if (self.revision == 0) {
            @memcpy(buf[0..self.version.len], self.version);
            return buf[0..self.version.len];
        }
        const rev_str = std.fmt.bufPrint(buf[self.version.len + 1 ..], "{d}", .{self.revision}) catch return self.version;
        @memcpy(buf[0..self.version.len], self.version);
        buf[self.version.len] = '_';
        return buf[0 .. self.version.len + 1 + rev_str.len];
    }
};

fn compareVersionStrings(a: []const u8, b: []const u8) std.math.Order {
    var a_iter = std.mem.splitScalar(u8, a, '.');
    var b_iter = std.mem.splitScalar(u8, b, '.');

    while (true) {
        const a_part = a_iter.next();
        const b_part = b_iter.next();

        if (a_part == null and b_part == null) return .eq;
        if (a_part == null) return .lt;
        if (b_part == null) return .gt;

        // Try numeric comparison first
        const a_num = std.fmt.parseInt(u64, a_part.?, 10) catch null;
        const b_num = std.fmt.parseInt(u64, b_part.?, 10) catch null;

        if (a_num != null and b_num != null) {
            const cmp = std.math.order(a_num.?, b_num.?);
            if (cmp != .eq) return cmp;
        } else {
            // Lexical comparison
            const cmp = std.mem.order(u8, a_part.?, b_part.?);
            if (cmp != .eq) return cmp;
        }
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `zig build test`
Expected: PASS

**Step 5: Update main.zig test block**

```zig
test {
    _ = @import("config.zig");
    _ = @import("dispatch.zig");
    _ = @import("version.zig");
}
```

**Step 6: Commit**

```bash
git add src/version.zig src/main.zig
git commit -m "feat: version parsing and comparison matching brew's PkgVersion"
```

---

## Phase 2: Cellar & First Commands (Tasks 7–10)

### Task 7: Cellar Scanner

**Files:**
- Create: `src/cellar.zig`

**Context:** The Cellar at `/opt/homebrew/Cellar` contains one directory per installed formula. Each formula dir contains version subdirectories. Each version dir has `INSTALL_RECEIPT.json` (the Tab file). Cellar scanning is needed by `list`, `outdated`, `leaves`, `info`, and more.

Cellar structure:
```
/opt/homebrew/Cellar/
├── bat/
│   └── 0.26.1/
│       ├── bin/bat
│       ├── INSTALL_RECEIPT.json
│       └── ...
├── git/
│   └── 2.47.1/
│       └── ...
```

**Step 1: Write failing tests**

```zig
const std = @import("std");

pub const InstalledFormula = struct {
    name: []const u8,
    versions: []const []const u8,

    pub fn latestVersion(self: InstalledFormula) []const u8 {
        // Versions are sorted, last is latest
        return self.versions[self.versions.len - 1];
    }
};

pub const Cellar = struct {
    path: []const u8,

    pub fn init(path: []const u8) Cellar {
        return .{ .path = path };
    }

    pub fn installedFormulae(self: Cellar, allocator: std.mem.Allocator) ![]InstalledFormula {
        _ = self;
        _ = allocator;
        unreachable;
    }

    pub fn isInstalled(self: Cellar, name: []const u8) bool {
        _ = self;
        _ = name;
        unreachable;
    }

    pub fn installedVersions(self: Cellar, allocator: std.mem.Allocator, name: []const u8) !?[]const []const u8 {
        _ = self;
        _ = allocator;
        _ = name;
        unreachable;
    }
};

test "Cellar isInstalled on real cellar" {
    const cellar = Cellar.init("/opt/homebrew/Cellar");
    // This test assumes brew is installed with at least one formula
    // We'll check a non-existent formula
    try std.testing.expect(!cellar.isInstalled("__nonexistent_formula_xyz__"));
}

test "Cellar installedFormulae returns non-empty list" {
    const cellar = Cellar.init("/opt/homebrew/Cellar");
    const formulae = try cellar.installedFormulae(std.testing.allocator);
    defer {
        for (formulae) |f| {
            for (f.versions) |v| std.testing.allocator.free(v);
            std.testing.allocator.free(f.versions);
            std.testing.allocator.free(f.name);
        }
        std.testing.allocator.free(formulae);
    }
    try std.testing.expect(formulae.len > 0);
}
```

**Step 2: Run tests to verify they fail**

Run: `zig build test`
Expected: FAIL

**Step 3: Implement Cellar**

```zig
pub fn isInstalled(self: Cellar, name: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ self.path, name }) catch return false;
    std.fs.accessAbsolute(full_path, .{}) catch return false;
    return true;
}

pub fn installedVersions(self: Cellar, allocator: std.mem.Allocator, name: []const u8) !?[]const []const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ self.path, name }) catch return null;
    var dir = std.fs.openDirAbsolute(full_path, .{ .iterate = true }) catch return null;
    defer dir.close();

    var versions = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (versions.items) |v| allocator.free(v);
        versions.deinit();
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.startsWith(u8, entry.name, ".")) continue;
        try versions.append(try allocator.dupe(u8, entry.name));
    }

    if (versions.items.len == 0) {
        versions.deinit();
        return null;
    }

    // Sort versions
    const items = try versions.toOwnedSlice();
    std.mem.sort([]const u8, items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return items;
}

pub fn installedFormulae(self: Cellar, allocator: std.mem.Allocator) ![]InstalledFormula {
    var dir = std.fs.openDirAbsolute(self.path, .{ .iterate = true }) catch return &.{};
    defer dir.close();

    var formulae = std.ArrayList(InstalledFormula).init(allocator);
    errdefer {
        for (formulae.items) |f| {
            for (f.versions) |v| allocator.free(v);
            allocator.free(f.versions);
            allocator.free(f.name);
        }
        formulae.deinit();
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.startsWith(u8, entry.name, ".")) continue;
        const name = try allocator.dupe(u8, entry.name);
        const versions = try self.installedVersions(allocator, entry.name) orelse continue;
        try formulae.append(.{ .name = name, .versions = versions });
    }

    const items = try formulae.toOwnedSlice();
    // Sort by name
    std.mem.sort(InstalledFormula, items, {}, struct {
        fn lessThan(_: void, a: InstalledFormula, b: InstalledFormula) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);
    return items;
}
```

**Step 4: Run tests to verify they pass**

Run: `zig build test`
Expected: PASS

**Step 5: Update main.zig test block**

Add `_ = @import("cellar.zig");` to the test block.

**Step 6: Commit**

```bash
git add src/cellar.zig src/main.zig
git commit -m "feat: cellar scanner reads installed formulae from filesystem"
```

---

### Task 8: `--prefix`, `--cellar`, `--cache`, `--version` Commands

**Files:**
- Create: `src/cmd/prefix.zig`
- Modify: `src/dispatch.zig`
- Modify: `src/main.zig`

**Context:** These are the simplest commands — instant returns of config values. `brew --prefix` prints `/opt/homebrew`. `brew --cellar` prints `/opt/homebrew/Cellar`. `brew --cache` prints `~/Library/Caches/Homebrew`. `brew --version` prints version string. These are dispatched via the alias system: `--prefix` → `__prefix`, etc.

`brew --prefix <formula>` is special: it prints the keg path (e.g., `/opt/homebrew/opt/bat`).

**Step 1: Create src/cmd/prefix.zig**

```zig
const std = @import("std");
const Config = @import("../config.zig").Config;

pub fn prefixCmd(_: std.mem.Allocator, args: []const []const u8, config: Config) !void {
    const stdout = std.io.getStdOut().writer();
    if (args.len > 0) {
        // --prefix <formula> → /opt/homebrew/opt/<formula>
        try stdout.print("{s}/opt/{s}\n", .{ config.prefix, args[0] });
    } else {
        try stdout.print("{s}\n", .{config.prefix});
    }
}

pub fn cellarCmd(_: std.mem.Allocator, args: []const []const u8, config: Config) !void {
    const stdout = std.io.getStdOut().writer();
    if (args.len > 0) {
        try stdout.print("{s}/{s}\n", .{ config.cellar, args[0] });
    } else {
        try stdout.print("{s}\n", .{config.cellar});
    }
}

pub fn cacheCmd(_: std.mem.Allocator, _: []const []const u8, config: Config) !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{s}\n", .{config.cache});
}
```

**Step 2: Add command registration to dispatch.zig**

Add a comptime map of native commands:

```zig
const prefix = @import("cmd/prefix.zig");

const native_commands = .{
    .{ "__prefix", prefix.prefixCmd },
    .{ "__cellar", prefix.cellarCmd },
    .{ "__cache", prefix.cacheCmd },
};

pub fn getCommand(name: []const u8) ?CommandFn {
    inline for (native_commands) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}
```

**Step 3: Wire into main.zig**

Replace the TODO in main.zig with actual dispatch:

```zig
if (parsed.command) |cmd_name| {
    if (dispatch.getCommand(cmd_name)) |cmd_fn| {
        try cmd_fn(allocator, parsed.command_args, config);
    } else {
        try fallback.execBrew(allocator, argv);
    }
}
```

**Step 4: Build and test**

Run: `zig build run -- --prefix`
Expected: `/opt/homebrew`

Run: `zig build run -- --cellar`
Expected: `/opt/homebrew/Cellar`

Run: `zig build run -- --cache`
Expected: `/Users/kylescully/Library/Caches/Homebrew`

Run: `zig build run -- --prefix bat`
Expected: `/opt/homebrew/opt/bat`

**Step 5: Commit**

```bash
git add src/cmd/prefix.zig src/dispatch.zig src/main.zig
git commit -m "feat: --prefix, --cellar, --cache commands"
```

---

### Task 9: `list` Command

**Files:**
- Create: `src/cmd/list.zig`
- Modify: `src/dispatch.zig`

**Context:** `brew list` (or `brew ls`) lists installed formulae. Default: one name per line, sorted. Key flags:
- `--formula` / `--cask`: filter type (default: formula)
- `-1`: one per line (this is actually the default for non-tty)
- `--versions`: show `name version` per line
- `--full-name`: show tap-qualified name (we skip this for now, just show name)

`brew list <formula>` lists files in a specific keg.

**Step 1: Create src/cmd/list.zig**

```zig
const std = @import("std");
const Config = @import("../config.zig").Config;
const Cellar = @import("../cellar.zig").Cellar;

pub fn listCmd(allocator: std.mem.Allocator, args: []const []const u8, config: Config) !void {
    const stdout = std.io.getStdOut().writer();

    var show_versions = false;
    var specific_formula: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--versions") or std.mem.eql(u8, arg, "-v")) {
            show_versions = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            specific_formula = arg;
        }
    }

    const cellar = Cellar.init(config.cellar);

    // List files for a specific formula
    if (specific_formula) |name| {
        const versions = try cellar.installedVersions(allocator, name) orelse {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("Error: No such keg: {s}/{s}\n", .{ config.cellar, name });
            std.process.exit(1);
        };
        defer {
            for (versions) |v| allocator.free(v);
            allocator.free(versions);
        }
        const latest = versions[versions.len - 1];
        try listKegFiles(stdout, config.cellar, name, latest);
        return;
    }

    // List all installed formulae
    const formulae = try cellar.installedFormulae(allocator);
    defer {
        for (formulae) |f| {
            for (f.versions) |v| allocator.free(v);
            allocator.free(f.versions);
            allocator.free(f.name);
        }
        allocator.free(formulae);
    }

    for (formulae) |f| {
        if (show_versions) {
            try stdout.print("{s}", .{f.name});
            for (f.versions) |v| {
                try stdout.print(" {s}", .{v});
            }
            try stdout.print("\n", .{});
        } else {
            try stdout.print("{s}\n", .{f.name});
        }
    }
}

fn listKegFiles(
    writer: std.fs.File.Writer,
    cellar_path: []const u8,
    name: []const u8,
    version: []const u8,
) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const keg_path = try std.fmt.bufPrint(&buf, "{s}/{s}/{s}", .{ cellar_path, name, version });
    var dir = try std.fs.openDirAbsolute(keg_path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        try writer.print("{s}/{s}/{s}/{s}\n", .{ cellar_path, name, version, entry.name });
    }
}
```

**Step 2: Register in dispatch.zig**

Add to `native_commands`:
```zig
const list = @import("cmd/list.zig");
// ...
.{ "list", list.listCmd },
```

**Step 3: Build and test**

Run: `zig build run -- list`
Expected: Sorted list of installed formula names, one per line (should match `brew list --formula -1`)

Run: `zig build run -- list --versions`
Expected: `name version` per line

Run: `zig build run -- ls`
Expected: Same as `list` (alias)

**Step 4: Compare output with brew**

Run: `diff <(zig build run -- list 2>/dev/null) <(brew list --formula -1 2>/dev/null)`
Expected: No differences (or minor ordering differences to investigate)

**Step 5: Commit**

```bash
git add src/cmd/list.zig src/dispatch.zig
git commit -m "feat: list command scans Cellar for installed formulae"
```

---

### Task 10: Tab File Reader

**Files:**
- Create: `src/tab.zig`

**Context:** `INSTALL_RECEIPT.json` is in every keg. We need to parse it for `info`, `outdated`, `leaves`, and more. Key fields: `installed_on_request` (bool), `poured_from_bottle` (bool), `runtime_dependencies` (array of `{full_name, version, revision}`), `source.spec` (`:stable` or `:head`), `time` (unix timestamp).

The file is standard JSON. Use `std.json` to parse it.

**Step 1: Write failing tests**

```zig
const std = @import("std");

pub const RuntimeDep = struct {
    full_name: []const u8,
    version: []const u8,
    revision: u32,
    pkg_version: []const u8,
    declared_directly: bool,
};

pub const Tab = struct {
    installed_on_request: bool,
    poured_from_bottle: bool,
    loaded_from_api: bool,
    time: ?i64,
    runtime_dependencies: []const RuntimeDep,
    compiler: []const u8,
    homebrew_version: []const u8,

    pub fn loadFromKeg(allocator: std.mem.Allocator, keg_path: []const u8) !?Tab {
        _ = allocator;
        _ = keg_path;
        unreachable;
    }

    pub fn deinit(self: *Tab, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
        unreachable;
    }
};

test "Tab loadFromKeg reads real tab" {
    var tab = (try Tab.loadFromKeg(std.testing.allocator, "/opt/homebrew/Cellar/bat/0.26.1")) orelse
        return error.SkipZigTest;
    defer tab.deinit(std.testing.allocator);
    try std.testing.expect(tab.poured_from_bottle);
    try std.testing.expect(tab.homebrew_version.len > 0);
}

test "Tab loadFromKeg returns null for nonexistent" {
    const result = try Tab.loadFromKeg(std.testing.allocator, "/nonexistent/path");
    try std.testing.expectEqual(@as(?Tab, null), result);
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL

**Step 3: Implement Tab**

```zig
pub fn loadFromKeg(allocator: std.mem.Allocator, keg_path: []const u8) !?Tab {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const receipt_path = std.fmt.bufPrint(&buf, "{s}/INSTALL_RECEIPT.json", .{keg_path}) catch return null;

    const file = std.fs.openFileAbsolute(receipt_path, .{}) catch return null;
    defer file.close();

    const contents = file.readToEndAlloc(allocator, 1024 * 1024) catch return null;
    defer allocator.free(contents);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value.object;

    // Parse runtime_dependencies
    var deps = std.ArrayList(RuntimeDep).init(allocator);
    errdefer deps.deinit();

    if (root.get("runtime_dependencies")) |deps_val| {
        if (deps_val == .array) {
            for (deps_val.array.items) |dep_val| {
                if (dep_val != .object) continue;
                const dep_obj = dep_val.object;
                try deps.append(.{
                    .full_name = try allocator.dupe(u8, jsonStr(dep_obj, "full_name") orelse ""),
                    .version = try allocator.dupe(u8, jsonStr(dep_obj, "version") orelse ""),
                    .revision = @intCast(jsonInt(dep_obj, "revision") orelse 0),
                    .pkg_version = try allocator.dupe(u8, jsonStr(dep_obj, "pkg_version") orelse ""),
                    .declared_directly = jsonBool(dep_obj, "declared_directly") orelse false,
                });
            }
        }
    }

    return Tab{
        .installed_on_request = jsonBool(root, "installed_on_request") orelse false,
        .poured_from_bottle = jsonBool(root, "poured_from_bottle") orelse false,
        .loaded_from_api = jsonBool(root, "loaded_from_api") orelse false,
        .time = jsonInt(root, "time"),
        .runtime_dependencies = try deps.toOwnedSlice(),
        .compiler = try allocator.dupe(u8, jsonStr(root, "compiler") orelse ""),
        .homebrew_version = try allocator.dupe(u8, jsonStr(root, "homebrew_version") orelse ""),
    };
}

pub fn deinit(self: *Tab, allocator: std.mem.Allocator) void {
    for (self.runtime_dependencies) |dep| {
        allocator.free(dep.full_name);
        allocator.free(dep.version);
        allocator.free(dep.pkg_version);
    }
    allocator.free(self.runtime_dependencies);
    allocator.free(self.compiler);
    allocator.free(self.homebrew_version);
}

fn jsonStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn jsonBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .bool => |b| b,
        else => null,
    };
}

fn jsonInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .integer => |i| i,
        else => null,
    };
}
```

**Step 4: Run tests to verify they pass**

Run: `zig build test`
Expected: PASS

**Step 5: Update main.zig test block**

Add `_ = @import("tab.zig");`

**Step 6: Commit**

```bash
git add src/tab.zig src/main.zig
git commit -m "feat: tab reader parses INSTALL_RECEIPT.json from kegs"
```

---

## Phase 3: Binary Index (Tasks 11–13)

### Task 11: JSON API Parser

**Files:**
- Create: `src/formula.zig`

**Context:** The formula.jws.json file (~31.8MB) contains a JWS envelope. The `payload` field is a raw JSON string (NOT base64 encoded) containing an array of ~8,237 formula objects. We need to parse this into a usable structure. For now, skip JWS verification — just parse the payload.

Each formula has: `name`, `full_name`, `desc`, `homepage`, `license`, `versions.stable`, `revision`, `bottle.stable.files`, `dependencies`, `build_dependencies`, `keg_only`, `deprecated`, `disabled`, `tap`.

**Step 1: Write failing test**

```zig
const std = @import("std");

pub const FormulaInfo = struct {
    name: []const u8,
    full_name: []const u8,
    desc: []const u8,
    homepage: []const u8,
    license: []const u8,
    version: []const u8,
    revision: u32,
    tap: []const u8,
    keg_only: bool,
    deprecated: bool,
    disabled: bool,
    dependencies: []const []const u8,
    build_dependencies: []const []const u8,
    bottle_root_url: []const u8,
    bottle_sha256: []const u8,
    bottle_cellar: []const u8,
};

pub fn parseFormulaJson(allocator: std.mem.Allocator, json_bytes: []const u8) ![]FormulaInfo {
    _ = allocator;
    _ = json_bytes;
    unreachable;
}

test "parseFormulaJson parses small payload" {
    const payload =
        \\[{"name":"test-formula","full_name":"test-formula","desc":"A test",
        \\"homepage":"https://example.com","license":"MIT",
        \\"versions":{"stable":"1.0.0","head":null,"bottle":true},
        \\"revision":0,"tap":"homebrew/core",
        \\"keg_only":false,"deprecated":false,"disabled":false,
        \\"dependencies":["dep1"],"build_dependencies":["bdep1"],
        \\"bottle":{"stable":{"rebuild":0,"root_url":"https://ghcr.io/v2/homebrew/core",
        \\"files":{"arm64_sequoia":{"cellar":":any","url":"https://example.com/bottle.tar.gz","sha256":"abc123"}}}}}]
    ;
    const formulae = try parseFormulaJson(std.testing.allocator, payload);
    defer {
        for (formulae) |f| freeFormula(std.testing.allocator, f);
        std.testing.allocator.free(formulae);
    }
    try std.testing.expectEqual(@as(usize, 1), formulae.len);
    try std.testing.expectEqualStrings("test-formula", formulae[0].name);
    try std.testing.expectEqualStrings("1.0.0", formulae[0].version);
    try std.testing.expectEqual(@as(usize, 1), formulae[0].dependencies.len);
}

pub fn freeFormula(allocator: std.mem.Allocator, f: FormulaInfo) void {
    _ = allocator;
    _ = f;
    unreachable;
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL

**Step 3: Implement parser**

The implementation should:
1. Parse JSON array
2. For each object, extract the needed fields
3. For bottle info, detect the current platform tag (e.g., `arm64_sequoia`) and extract that bottle's sha256 and cellar

```zig
pub fn parseFormulaJson(allocator: std.mem.Allocator, json_bytes: []const u8) ![]FormulaInfo {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    if (parsed.value != .array) return error.InvalidFormat;

    var formulae = std.ArrayList(FormulaInfo).init(allocator);
    errdefer {
        for (formulae.items) |f| freeFormula(allocator, f);
        formulae.deinit();
    }

    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;

        const name = try allocator.dupe(u8, jsonStr(obj, "name") orelse continue);
        errdefer allocator.free(name);

        const full_name = try allocator.dupe(u8, jsonStr(obj, "full_name") orelse name);
        const desc = try allocator.dupe(u8, jsonStr(obj, "desc") orelse "");
        const homepage = try allocator.dupe(u8, jsonStr(obj, "homepage") orelse "");
        const license = try allocator.dupe(u8, jsonStr(obj, "license") orelse "");
        const tap = try allocator.dupe(u8, jsonStr(obj, "tap") orelse "homebrew/core");

        // versions.stable
        var version: []const u8 = "";
        if (obj.get("versions")) |ver_val| {
            if (ver_val == .object) {
                version = jsonStr(ver_val.object, "stable") orelse "";
            }
        }
        const version_owned = try allocator.dupe(u8, version);

        const revision: u32 = @intCast(@max(0, jsonInt(obj, "revision") orelse 0));
        const keg_only = jsonBool(obj, "keg_only") orelse false;
        const deprecated = jsonBool(obj, "deprecated") orelse false;
        const disabled = jsonBool(obj, "disabled") orelse false;

        // dependencies
        const deps = try parseStringArray(allocator, obj.get("dependencies"));
        const build_deps = try parseStringArray(allocator, obj.get("build_dependencies"));

        // bottle info for current platform
        var bottle_root_url: []const u8 = "";
        var bottle_sha256: []const u8 = "";
        var bottle_cellar: []const u8 = "";
        if (obj.get("bottle")) |bottle_val| {
            if (bottle_val == .object) {
                if (bottle_val.object.get("stable")) |stable_val| {
                    if (stable_val == .object) {
                        bottle_root_url = jsonStr(stable_val.object, "root_url") orelse "";
                        if (stable_val.object.get("files")) |files_val| {
                            if (files_val == .object) {
                                // Try current platform tag first
                                const tag = currentPlatformTag();
                                if (files_val.object.get(tag)) |file_val| {
                                    if (file_val == .object) {
                                        bottle_sha256 = jsonStr(file_val.object, "sha256") orelse "";
                                        bottle_cellar = jsonStr(file_val.object, "cellar") orelse "";
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        try formulae.append(.{
            .name = name,
            .full_name = full_name,
            .desc = desc,
            .homepage = homepage,
            .license = license,
            .version = version_owned,
            .revision = revision,
            .tap = tap,
            .keg_only = keg_only,
            .deprecated = deprecated,
            .disabled = disabled,
            .dependencies = deps,
            .build_dependencies = build_deps,
            .bottle_root_url = try allocator.dupe(u8, bottle_root_url),
            .bottle_sha256 = try allocator.dupe(u8, bottle_sha256),
            .bottle_cellar = try allocator.dupe(u8, bottle_cellar),
        });
    }

    return try formulae.toOwnedSlice();
}

pub fn freeFormula(allocator: std.mem.Allocator, f: FormulaInfo) void {
    allocator.free(f.name);
    allocator.free(f.full_name);
    allocator.free(f.desc);
    allocator.free(f.homepage);
    allocator.free(f.license);
    allocator.free(f.version);
    allocator.free(f.tap);
    for (f.dependencies) |d| allocator.free(d);
    allocator.free(f.dependencies);
    for (f.build_dependencies) |d| allocator.free(d);
    allocator.free(f.build_dependencies);
    allocator.free(f.bottle_root_url);
    allocator.free(f.bottle_sha256);
    allocator.free(f.bottle_cellar);
}

fn parseStringArray(allocator: std.mem.Allocator, val: ?std.json.Value) ![]const []const u8 {
    const v = val orelse return &.{};
    if (v != .array) return &.{};

    var list = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit();
    }

    for (v.array.items) |item| {
        if (item == .string) {
            try list.append(try allocator.dupe(u8, item.string));
        }
    }
    return try list.toOwnedSlice();
}

fn currentPlatformTag() []const u8 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .macos) {
        if (builtin.cpu.arch == .aarch64) return "arm64_sequoia";
        return "sequoia";
    }
    if (builtin.os.tag == .linux) {
        if (builtin.cpu.arch == .aarch64) return "aarch64_linux";
        return "x86_64_linux";
    }
    return "all";
}

fn jsonStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn jsonBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .bool => |b| b,
        else => null,
    };
}

fn jsonInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .integer => |i| i,
        else => null,
    };
}
```

**Step 4: Run tests to verify they pass**

Run: `zig build test`
Expected: PASS

**Step 5: Add test that loads real JWS file**

Add a second test that loads the actual formula.jws.json from disk:

```zig
test "parseFormulaJson loads real JWS payload" {
    // Load the JWS file
    const home = std.process.getEnvVarOwned(std.testing.allocator, "HOME") catch return;
    defer std.testing.allocator.free(home);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/Library/Caches/Homebrew/api/formula.jws.json", .{home}) catch return;

    const file = std.fs.openFileAbsolute(path, .{}) catch return;
    defer file.close();

    const contents = file.readToEndAlloc(std.testing.allocator, 64 * 1024 * 1024) catch return;
    defer std.testing.allocator.free(contents);

    // Parse JWS envelope to get payload
    const jws = std.json.parseFromSlice(std.json.Value, std.testing.allocator, contents, .{
        .allocate = .alloc_always,
    }) catch return;
    defer jws.deinit();

    const payload_str = jsonStr(jws.value.object, "payload") orelse return;

    const formulae = try parseFormulaJson(std.testing.allocator, payload_str);
    defer {
        for (formulae) |f| freeFormula(std.testing.allocator, f);
        std.testing.allocator.free(formulae);
    }

    // Should have thousands of formulae
    try std.testing.expect(formulae.len > 5000);

    // Find bat
    for (formulae) |f| {
        if (std.mem.eql(u8, f.name, "bat")) {
            try std.testing.expectEqualStrings("bat", f.name);
            try std.testing.expect(f.version.len > 0);
            return;
        }
    }
    return error.BatNotFound;
}
```

**Step 6: Run tests**

Run: `zig build test`
Expected: PASS (may take a few seconds for the large JSON parse)

**Step 7: Commit**

```bash
git add src/formula.zig src/main.zig
git commit -m "feat: formula JSON parser extracts formula info from API payload"
```

---

### Task 12: Binary Index Builder

**Files:**
- Create: `src/index.zig`

**Context:** Build a memory-mappable binary index from parsed formula data. The index uses open-addressing hash table for O(1) lookups by name. Layout from design doc:
- Header (64 bytes): magic, version, source_hash, entry_count, offsets
- Hash Table: open addressing, 2x capacity
- Entries: fixed-size records
- String Table: packed null-terminated strings

For now, implement build + lookup + iterate. Staleness detection comes later.

**Step 1: Write failing tests**

```zig
const std = @import("std");
const formula = @import("formula.zig");

pub const IndexHeader = extern struct {
    magic: [4]u8,
    version: u32,
    source_hash: [32]u8,
    entry_count: u32,
    _pad: [4]u8,
    hash_table_offset: u64,
    entries_offset: u64,
    strings_offset: u64,
};

pub const IndexEntry = extern struct {
    name_offset: u32,
    full_name_offset: u32,
    desc_offset: u32,
    version_offset: u32,
    revision: u16,
    flags: u16, // bottle_available, deprecated, disabled, keg_only packed
    deps_offset: u32,
    build_deps_offset: u32,
    tap_offset: u32,
    homepage_offset: u32,
    license_offset: u32,
    bottle_root_url_offset: u32,
    bottle_sha256_offset: u32,
    bottle_cellar_offset: u32,
};

pub const Index = struct {
    // Will hold mmap'd data or built data
    data: []align(std.mem.page_size) const u8,

    pub fn build(allocator: std.mem.Allocator, formulae: []const formula.FormulaInfo) !Index {
        _ = allocator;
        _ = formulae;
        unreachable;
    }

    pub fn lookup(self: Index, name: []const u8) ?IndexEntry {
        _ = self;
        _ = name;
        unreachable;
    }

    pub fn getString(self: Index, offset: u32) []const u8 {
        _ = self;
        _ = offset;
        unreachable;
    }

    pub fn entryCount(self: Index) u32 {
        _ = self;
        unreachable;
    }
};

test "build and lookup" {
    const f = [_]formula.FormulaInfo{.{
        .name = "test-pkg",
        .full_name = "test-pkg",
        .desc = "A test package",
        .homepage = "https://example.com",
        .license = "MIT",
        .version = "1.0.0",
        .revision = 0,
        .tap = "homebrew/core",
        .keg_only = false,
        .deprecated = false,
        .disabled = false,
        .dependencies = &.{},
        .build_dependencies = &.{},
        .bottle_root_url = "",
        .bottle_sha256 = "",
        .bottle_cellar = "",
    }};

    const index = try Index.build(std.testing.allocator, &f);
    defer std.testing.allocator.free(index.data);

    try std.testing.expectEqual(@as(u32, 1), index.entryCount());

    const entry = index.lookup("test-pkg") orelse return error.NotFound;
    try std.testing.expectEqualStrings("test-pkg", index.getString(entry.name_offset));
    try std.testing.expectEqualStrings("1.0.0", index.getString(entry.version_offset));
}

test "lookup missing returns null" {
    const f = [_]formula.FormulaInfo{.{
        .name = "exists",
        .full_name = "exists",
        .desc = "",
        .homepage = "",
        .license = "",
        .version = "1.0",
        .revision = 0,
        .tap = "",
        .keg_only = false,
        .deprecated = false,
        .disabled = false,
        .dependencies = &.{},
        .build_dependencies = &.{},
        .bottle_root_url = "",
        .bottle_sha256 = "",
        .bottle_cellar = "",
    }};

    const index = try Index.build(std.testing.allocator, &f);
    defer std.testing.allocator.free(index.data);

    try std.testing.expectEqual(@as(?IndexEntry, null), index.lookup("nonexistent"));
}
```

**Step 2: Run tests to verify they fail**

Run: `zig build test`
Expected: FAIL

**Step 3: Implement Index.build, lookup, getString, entryCount**

This is the most complex module. The build process:
1. Collect all strings into a string table, recording offsets
2. Build entry records using string offsets
3. Build hash table (open addressing, FNV-1a hash, 2x capacity)
4. Concatenate: header + hash_table + entries + strings
5. Return as a contiguous byte slice

The implementation should be written carefully. Here's the approach:

```zig
const MAGIC = [4]u8{ 'B', 'R', 'U', 'I' };
const INDEX_VERSION: u32 = 1;

pub fn build(allocator: std.mem.Allocator, formulae: []const formula.FormulaInfo) !Index {
    // String table builder
    var strings = std.ArrayList(u8).init(allocator);
    defer strings.deinit();

    // Add empty string at offset 0
    try strings.append(0);

    const addString = struct {
        fn f(list: *std.ArrayList(u8), s: []const u8) !u32 {
            if (s.len == 0) return 0;
            const offset: u32 = @intCast(list.items.len);
            try list.appendSlice(s);
            try list.append(0);
            return offset;
        }
    }.f;

    // Add string list and return offset to length-prefixed array
    const addStringList = struct {
        fn f(list: *std.ArrayList(u8), items: []const []const u8) !u32 {
            if (items.len == 0) return 0;
            const offset: u32 = @intCast(list.items.len);
            // Length prefix as u32 LE
            const len_bytes = std.mem.toBytes(@as(u32, @intCast(items.len)));
            try list.appendSlice(&len_bytes);
            for (items) |item| {
                const str_len = std.mem.toBytes(@as(u32, @intCast(item.len)));
                try list.appendSlice(&str_len);
                try list.appendSlice(item);
            }
            return offset;
        }
    }.f;

    // Build entries
    var entries = try allocator.alloc(IndexEntry, formulae.len);
    defer allocator.free(entries);

    for (formulae, 0..) |fm, i| {
        var flags: u16 = 0;
        if (fm.keg_only) flags |= 1;
        if (fm.deprecated) flags |= 2;
        if (fm.disabled) flags |= 4;
        if (fm.bottle_sha256.len > 0) flags |= 8; // bottle_available

        entries[i] = .{
            .name_offset = try addString(&strings, fm.name),
            .full_name_offset = try addString(&strings, fm.full_name),
            .desc_offset = try addString(&strings, fm.desc),
            .version_offset = try addString(&strings, fm.version),
            .revision = @intCast(fm.revision),
            .flags = flags,
            .deps_offset = try addStringList(&strings, fm.dependencies),
            .build_deps_offset = try addStringList(&strings, fm.build_dependencies),
            .tap_offset = try addString(&strings, fm.tap),
            .homepage_offset = try addString(&strings, fm.homepage),
            .license_offset = try addString(&strings, fm.license),
            .bottle_root_url_offset = try addString(&strings, fm.bottle_root_url),
            .bottle_sha256_offset = try addString(&strings, fm.bottle_sha256),
            .bottle_cellar_offset = try addString(&strings, fm.bottle_cellar),
        };
    }

    // Build hash table (open addressing, 2x capacity)
    const bucket_count: u32 = @intCast(@max(16, formulae.len * 2));
    const HashBucket = extern struct { string_offset: u32, entry_index: u32 };
    var hash_table = try allocator.alloc(HashBucket, bucket_count);
    defer allocator.free(hash_table);
    @memset(hash_table, .{ .string_offset = 0, .entry_index = std.math.maxInt(u32) });

    for (entries, 0..) |entry, i| {
        const name = getString_raw(strings.items, entry.name_offset);
        var slot = fnvHash(name) % bucket_count;
        while (hash_table[slot].entry_index != std.math.maxInt(u32)) {
            slot = (slot + 1) % bucket_count;
        }
        hash_table[slot] = .{ .string_offset = entry.name_offset, .entry_index = @intCast(i) };
    }

    // Calculate layout
    const header_size: u64 = @sizeOf(IndexHeader);
    const hash_table_size: u64 = bucket_count * @sizeOf(HashBucket);
    const entries_size: u64 = formulae.len * @sizeOf(IndexEntry);
    const total_size = header_size + hash_table_size + entries_size + strings.items.len;

    // Allocate aligned buffer
    const data = try allocator.alignedAlloc(u8, std.mem.page_size, total_size);
    errdefer allocator.free(data);

    // Write header
    const header = IndexHeader{
        .magic = MAGIC,
        .version = INDEX_VERSION,
        .source_hash = [_]u8{0} ** 32,
        .entry_count = @intCast(formulae.len),
        ._pad = [_]u8{0} ** 4,
        .hash_table_offset = header_size,
        .entries_offset = header_size + hash_table_size,
        .strings_offset = header_size + hash_table_size + entries_size,
    };
    @memcpy(data[0..@sizeOf(IndexHeader)], std.mem.asBytes(&header));

    // Write hash table
    const ht_bytes = std.mem.sliceAsBytes(hash_table);
    @memcpy(data[@intCast(header.hash_table_offset)..][0..ht_bytes.len], ht_bytes);

    // Write entries
    const entry_bytes = std.mem.sliceAsBytes(entries);
    @memcpy(data[@intCast(header.entries_offset)..][0..entry_bytes.len], entry_bytes);

    // Write strings
    @memcpy(data[@intCast(header.strings_offset)..][0..strings.items.len], strings.items);

    return .{ .data = data };
}

pub fn entryCount(self: Index) u32 {
    const header = self.getHeader();
    return header.entry_count;
}

pub fn lookup(self: Index, name: []const u8) ?IndexEntry {
    const header = self.getHeader();
    const bucket_count = @divExact(
        header.entries_offset - header.hash_table_offset,
        8, // size of HashBucket
    );

    var slot = fnvHash(name) % @as(u32, @intCast(bucket_count));
    var probes: u32 = 0;
    while (probes < bucket_count) : (probes += 1) {
        const bucket_offset = header.hash_table_offset + slot * 8;
        const entry_index = std.mem.readInt(u32, self.data[@intCast(bucket_offset + 4)..][0..4], .little);
        if (entry_index == std.math.maxInt(u32)) return null;

        const str_offset = std.mem.readInt(u32, self.data[@intCast(bucket_offset)..][0..4], .little);
        const bucket_name = self.getString(str_offset);
        if (std.mem.eql(u8, bucket_name, name)) {
            return self.getEntry(entry_index);
        }
        slot = (slot + 1) % @as(u32, @intCast(bucket_count));
    }
    return null;
}

pub fn getString(self: Index, offset: u32) []const u8 {
    return getString_raw(self.data, @as(u32, @intCast(self.getHeader().strings_offset)) + offset);
}

fn getString_raw(data: []const u8, abs_offset: u32) []const u8 {
    if (abs_offset >= data.len) return "";
    const start = data[abs_offset..];
    const end = std.mem.indexOfScalar(u8, start, 0) orelse return start;
    return start[0..end];
}

fn getHeader(self: Index) IndexHeader {
    return std.mem.bytesAsValue(IndexHeader, self.data[0..@sizeOf(IndexHeader)]).*;
}

fn getEntry(self: Index, idx: u32) IndexEntry {
    const header = self.getHeader();
    const offset = header.entries_offset + idx * @sizeOf(IndexEntry);
    return std.mem.bytesAsValue(IndexEntry, self.data[@intCast(offset)..][0..@sizeOf(IndexEntry)]).*;
}

fn fnvHash(s: []const u8) u32 {
    var h: u32 = 2166136261;
    for (s) |byte| {
        h ^= byte;
        h *%= 16777619;
    }
    return h;
}
```

Note: `getString` adds the `strings_offset` from the header — the string offsets stored in entries are relative to the string table start, not the overall buffer. Actually wait — in the `addString` function, offsets are relative to `strings.items` start. When we write to the final buffer, strings start at `header.strings_offset`. So `getString` must add the base. Let me reconsider...

Actually, let's keep string offsets as relative to the strings section. In `getString`, we add `strings_offset` to the entry's offset to get the absolute position in the data buffer. The `getString_raw` used during build works differently — it operates on the raw strings buffer directly. We need two variants.

**Step 4: Run tests to verify they pass**

Run: `zig build test`
Expected: PASS

**Step 5: Commit**

```bash
git add src/index.zig src/main.zig
git commit -m "feat: binary index builder with hash table lookup"
```

---

### Task 13: Index File I/O (Write to Disk, mmap from Disk)

**Files:**
- Modify: `src/index.zig`

**Context:** The index needs to be saved to disk alongside the JSON cache and loaded via mmap on subsequent runs. File location: `~/Library/Caches/Homebrew/api/formula.bru.idx`. Staleness detection: SHA-256 of the source JSON stored in header.

**Step 1: Add writeToDisk and openFromDisk methods with tests**

```zig
pub fn writeToDisk(self: Index, path: []const u8) !void {
    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(self.data);
}

pub fn openFromDisk(path: []const u8) !?Index {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const stat = try file.stat();
    if (stat.size < @sizeOf(IndexHeader)) return null;
    const data = try std.posix.mmap(null, stat.size, std.posix.PROT.READ, .{ .TYPE = .PRIVATE }, file.handle, 0);
    // Verify magic
    if (!std.mem.eql(u8, data[0..4], &MAGIC)) return null;
    return .{ .data = data };
}

pub fn loadOrBuild(allocator: std.mem.Allocator, cache_dir: []const u8) !Index {
    // Try loading existing index
    var idx_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const idx_path = try std.fmt.bufPrint(&idx_path_buf, "{s}/api/formula.bru.idx", .{cache_dir});

    if (try openFromDisk(idx_path)) |idx| {
        // TODO: staleness check with source hash
        return idx;
    }

    // Build from JSON
    var json_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const json_path = try std.fmt.bufPrint(&json_path_buf, "{s}/api/formula.jws.json", .{cache_dir});

    const file = try std.fs.openFileAbsolute(json_path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, 64 * 1024 * 1024);
    defer allocator.free(contents);

    // Parse JWS envelope
    const jws = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{
        .allocate = .alloc_always,
    });
    defer jws.deinit();

    const payload_str = jws.value.object.get("payload").?.string;

    // Parse formulae
    const formulae_mod = @import("formula.zig");
    const formulae = try formulae_mod.parseFormulaJson(allocator, payload_str);
    defer {
        for (formulae) |f| formulae_mod.freeFormula(allocator, f);
        allocator.free(formulae);
    }

    // Build index
    const index = try build(allocator, formulae);

    // Write to disk for next time
    index.writeToDisk(idx_path) catch {}; // best-effort

    return index;
}
```

**Step 2: Test**

```zig
test "loadOrBuild from real cache" {
    const home = std.process.getEnvVarOwned(std.testing.allocator, "HOME") catch return;
    defer std.testing.allocator.free(home);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache = std.fmt.bufPrint(&buf, "{s}/Library/Caches/Homebrew", .{home}) catch return;

    const index = Index.loadOrBuild(std.testing.allocator, cache) catch return;
    // Don't free mmap'd data in test

    try std.testing.expect(index.entryCount() > 5000);
    const bat = index.lookup("bat") orelse return error.NotFound;
    try std.testing.expectEqualStrings("bat", index.getString(bat.name_offset));
}
```

**Step 3: Run tests**

Run: `zig build test`
Expected: PASS (first run builds index, subsequent runs load from mmap)

**Step 4: Commit**

```bash
git add src/index.zig
git commit -m "feat: index file I/O with mmap loading and loadOrBuild"
```

---

## Phase 4: Tier 1 Commands (Tasks 14–19)

### Task 14: `search` Command

**Files:**
- Create: `src/cmd/search.zig`
- Modify: `src/dispatch.zig`

**Context:** `brew search <text>` does substring match against all formula names. `brew search /<regex>/` does regex match. Output: names separated by newlines, no decoration.

For our first pass, implement substring search by iterating all entries in the index.

**Step 1: Create src/cmd/search.zig**

```zig
const std = @import("std");
const Config = @import("../config.zig").Config;
const Index = @import("../index.zig").Index;

pub fn searchCmd(allocator: std.mem.Allocator, args: []const []const u8, config: Config) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len == 0) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Usage: bru search <text>\n", .{});
        std.process.exit(1);
    }

    const query = args[0];
    const index = try Index.loadOrBuild(allocator, config.cache);

    // Iterate all entries and match
    const header = std.mem.bytesAsValue(
        @import("../index.zig").IndexHeader,
        index.data[0..@sizeOf(@import("../index.zig").IndexHeader)],
    ).*;

    var count: u32 = 0;
    var i: u32 = 0;
    while (i < header.entry_count) : (i += 1) {
        const entry = index.getEntryByIndex(i);
        const name = index.getString(entry.name_offset);
        if (std.mem.indexOf(u8, name, query) != null) {
            try stdout.print("{s}\n", .{name});
            count += 1;
        }
    }

    if (count == 0) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("No formulae found for \"{s}\".\n", .{query});
        std.process.exit(1);
    }
}
```

Note: We'll need to expose `getEntryByIndex` as a public method on `Index`. Add it to `src/index.zig`:

```zig
pub fn getEntryByIndex(self: Index, idx: u32) IndexEntry {
    return self.getEntry(idx);
}
```

**Step 2: Register in dispatch.zig**

```zig
const search = @import("cmd/search.zig");
.{ "search", search.searchCmd },
```

**Step 3: Build and test**

Run: `zig build run -- search bat`
Expected: List of formulae containing "bat" (should include bat, bats-core, etc.)

Compare: `diff <(zig build run -- search bat 2>/dev/null | sort) <(brew search bat 2>/dev/null | grep -v '==> ' | sort)`

**Step 4: Commit**

```bash
git add src/cmd/search.zig src/dispatch.zig src/index.zig
git commit -m "feat: search command with substring matching over index"
```

---

### Task 15: `info` Command

**Files:**
- Create: `src/cmd/info.zig`
- Modify: `src/dispatch.zig`

**Context:** `brew info <formula>` prints detailed info. Format (from `brew info bat`):

```
==> bat: stable 0.26.1 (bottled), HEAD
Clone of cat(1) with syntax highlighting and Git integration
https://github.com/sharkdp/bat
Installed
/opt/homebrew/Cellar/bat/0.26.1 (15 files, 5.0MB) *
  Poured from bottle using the formulae.brew.sh API on 2026-02-25 at 21:51:20
From: https://github.com/Homebrew/homebrew-core/blob/HEAD/Formula/b/bat.rb
License: Apache-2.0 OR MIT
==> Dependencies
Build: pkgconf, rust
Required: libgit2, oniguruma
```

We match this format. We need index lookup + cellar check + tab reading.

**Step 1: Create src/cmd/info.zig**

```zig
const std = @import("std");
const Config = @import("../config.zig").Config;
const Index = @import("../index.zig").Index;
const Cellar = @import("../cellar.zig").Cellar;
const Tab = @import("../tab.zig").Tab;
const Output = @import("../output.zig").Output;

pub fn infoCmd(allocator: std.mem.Allocator, args: []const []const u8, config: Config) !void {
    if (args.len == 0) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Usage: bru info <formula>\n", .{});
        std.process.exit(1);
    }

    const name = args[0];
    const index = try Index.loadOrBuild(allocator, config.cache);
    const entry = index.lookup(name) orelse {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Error: No available formula with the name \"{s}\".\n", .{name});
        std.process.exit(1);
    };

    const out = Output.init(config.no_color);
    const version = index.getString(entry.version_offset);
    const desc = index.getString(entry.desc_offset);
    const homepage = index.getString(entry.homepage_offset);
    const license = index.getString(entry.license_offset);

    // Header: ==> name: stable version (bottled)
    const has_bottle = (entry.flags & 8) != 0;
    if (has_bottle) {
        try out.section(try std.fmt.allocPrint(allocator, "{s}: stable {s} (bottled)", .{ name, version }));
    } else {
        try out.section(try std.fmt.allocPrint(allocator, "{s}: stable {s}", .{ name, version }));
    }

    // Description
    if (desc.len > 0) try out.print("{s}\n", .{desc});

    // Homepage
    if (homepage.len > 0) try out.print("{s}\n", .{homepage});

    // Installed status
    const cellar = Cellar.init(config.cellar);
    if (try cellar.installedVersions(allocator, name)) |versions| {
        try out.print("Installed\n", .{});
        for (versions) |ver| {
            var keg_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const keg_path = try std.fmt.bufPrint(&keg_path_buf, "{s}/{s}/{s}", .{ config.cellar, name, ver });
            // Count files in keg
            try out.print("{s}/{s}/{s}\n", .{ config.cellar, name, ver });

            // Read tab for install info
            var tab = (try Tab.loadFromKeg(allocator, keg_path)) orelse continue;
            defer tab.deinit(allocator);
            if (tab.poured_from_bottle) {
                try out.print("  Poured from bottle\n", .{});
            }
        }
    } else {
        try out.print("Not installed\n", .{});
    }

    // License
    if (license.len > 0) {
        try out.print("License: {s}\n", .{license});
    }

    // Dependencies
    const deps = index.getStringList(entry.deps_offset);
    const build_deps = index.getStringList(entry.build_deps_offset);

    if (deps.len > 0 or build_deps.len > 0) {
        try out.section("Dependencies");
        if (build_deps.len > 0) {
            try out.print("Build: ", .{});
            for (build_deps, 0..) |d, i| {
                if (i > 0) try out.print(", ", .{});
                try out.print("{s}", .{d});
            }
            try out.print("\n", .{});
        }
        if (deps.len > 0) {
            try out.print("Required: ", .{});
            for (deps, 0..) |d, i| {
                if (i > 0) try out.print(", ", .{});
                try out.print("{s}", .{d});
            }
            try out.print("\n", .{});
        }
    }
}
```

Note: We need to add `getStringList` to `Index` to decode the length-prefixed string list format:

```zig
pub fn getStringList(self: Index, offset: u32) []const []const u8 {
    // Decode length-prefixed array from string table
    // Returns a slice view — caller should not free
    // Actually, we need to allocate... for now return empty
    // TODO: implement properly
    _ = self;
    if (offset == 0) return &.{};
    return &.{};
}
```

This needs more thought — `getStringList` can't return a slice without allocation. We'll use a temporary buffer approach. Better approach: store a small fixed-size array.

For the plan, implement `getStringList` using a thread-local static buffer, or accept an allocator parameter.

**Step 2: Register in dispatch.zig**

```zig
const info = @import("cmd/info.zig");
.{ "info", info.infoCmd },
```

**Step 3: Build and test**

Run: `zig build run -- info bat`
Expected: Info output similar to brew's format

**Step 4: Commit**

```bash
git add src/cmd/info.zig src/dispatch.zig src/index.zig
git commit -m "feat: info command with index lookup and cellar status"
```

---

### Task 16: `outdated` Command

**Files:**
- Create: `src/cmd/outdated.zig`
- Modify: `src/dispatch.zig`

**Context:** `brew outdated` compares installed versions against the latest in the index. Prints `name (installed) < latest` or just names. Key flags: `--verbose` (show versions), `--json` (JSON output).

**Step 1: Create src/cmd/outdated.zig**

```zig
const std = @import("std");
const Config = @import("../config.zig").Config;
const Index = @import("../index.zig").Index;
const Cellar = @import("../cellar.zig").Cellar;
const PkgVersion = @import("../version.zig").PkgVersion;

pub fn outdatedCmd(allocator: std.mem.Allocator, args: []const []const u8, config: Config) !void {
    const stdout = std.io.getStdOut().writer();
    var verbose = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) verbose = true;
    }

    const index = try Index.loadOrBuild(allocator, config.cache);
    const cellar = Cellar.init(config.cellar);
    const installed = try cellar.installedFormulae(allocator);
    defer {
        for (installed) |f| {
            for (f.versions) |v| allocator.free(v);
            allocator.free(f.versions);
            allocator.free(f.name);
        }
        allocator.free(installed);
    }

    for (installed) |f| {
        const entry = index.lookup(f.name) orelse continue;
        const latest_version = index.getString(entry.version_offset);
        const latest = PkgVersion{ .version = latest_version, .revision = entry.revision };

        const installed_ver = f.latestVersion();
        const current = PkgVersion.parse(installed_ver);

        if (current.order(latest) == .lt) {
            if (verbose) {
                try stdout.print("{s} ({s}) < {s}\n", .{ f.name, installed_ver, latest_version });
            } else {
                try stdout.print("{s}\n", .{f.name});
            }
        }
    }
}
```

**Step 2: Register in dispatch.zig**

```zig
const outdated = @import("cmd/outdated.zig");
.{ "outdated", outdated.outdatedCmd },
```

**Step 3: Build and test**

Run: `zig build run -- outdated`
Expected: List of outdated formulae (or empty if all up to date)

Compare: `diff <(zig build run -- outdated 2>/dev/null) <(brew outdated 2>/dev/null)`

**Step 4: Commit**

```bash
git add src/cmd/outdated.zig src/dispatch.zig
git commit -m "feat: outdated command compares installed vs index versions"
```

---

### Task 17: `deps` Command

**Files:**
- Create: `src/cmd/deps.zig`
- Modify: `src/dispatch.zig`

**Context:** `brew deps <formula>` lists dependencies. `brew deps --tree <formula>` shows tree view. For now, implement flat listing using the index's dependency data.

**Step 1: Create src/cmd/deps.zig**

```zig
const std = @import("std");
const Config = @import("../config.zig").Config;
const Index = @import("../index.zig").Index;

pub fn depsCmd(allocator: std.mem.Allocator, args: []const []const u8, config: Config) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len == 0) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Usage: bru deps <formula>\n", .{});
        std.process.exit(1);
    }

    var formula_name: ?[]const u8 = null;
    var include_build = false;
    var tree_mode = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--include-build")) {
            include_build = true;
        } else if (std.mem.eql(u8, arg, "--tree")) {
            tree_mode = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            formula_name = arg;
        }
    }

    const name = formula_name orelse {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Usage: bru deps <formula>\n", .{});
        std.process.exit(1);
    };

    const index = try Index.loadOrBuild(allocator, config.cache);
    const entry = index.lookup(name) orelse {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Error: No available formula with the name \"{s}\".\n", .{name});
        std.process.exit(1);
    };

    // Get direct dependencies
    const deps = index.getStringList(allocator, entry.deps_offset) catch &.{};
    const build_deps = if (include_build)
        index.getStringList(allocator, entry.build_deps_offset) catch &.{}
    else
        &[_][]const u8{};

    for (deps) |d| {
        try stdout.print("{s}\n", .{d});
    }
    for (build_deps) |d| {
        try stdout.print("{s}\n", .{d});
    }
}
```

Note: `getStringList` now takes an allocator. Update `Index` accordingly:

```zig
pub fn getStringList(self: Index, allocator: std.mem.Allocator, offset: u32) ![]const []const u8 {
    if (offset == 0) return &.{};
    const base = @as(usize, self.getHeader().strings_offset) + offset;
    if (base + 4 > self.data.len) return &.{};
    const count = std.mem.readInt(u32, self.data[base..][0..4], .little);
    var list = try allocator.alloc([]const u8, count);
    var pos = base + 4;
    for (0..count) |i| {
        if (pos + 4 > self.data.len) break;
        const str_len = std.mem.readInt(u32, self.data[pos..][0..4], .little);
        pos += 4;
        if (pos + str_len > self.data.len) break;
        list[i] = self.data[pos..][0..str_len];
        pos += str_len;
    }
    return list;
}
```

**Step 2: Register in dispatch.zig**

```zig
const deps = @import("cmd/deps.zig");
.{ "deps", deps.depsCmd },
```

**Step 3: Build and test**

Run: `zig build run -- deps bat`
Expected: List of bat's dependencies

**Step 4: Commit**

```bash
git add src/cmd/deps.zig src/dispatch.zig src/index.zig
git commit -m "feat: deps command lists formula dependencies from index"
```

---

### Task 18: `leaves` Command

**Files:**
- Create: `src/cmd/leaves.zig`
- Modify: `src/dispatch.zig`

**Context:** `brew leaves` shows installed formulae that are not dependencies of any other installed formula. Algorithm: get all installed formulae, build set of all dependencies of installed formulae, return installed formulae not in that set. Also filter to only `installed_on_request`.

**Step 1: Create src/cmd/leaves.zig**

```zig
const std = @import("std");
const Config = @import("../config.zig").Config;
const Index = @import("../index.zig").Index;
const Cellar = @import("../cellar.zig").Cellar;
const Tab = @import("../tab.zig").Tab;

pub fn leavesCmd(allocator: std.mem.Allocator, _: []const []const u8, config: Config) !void {
    const stdout = std.io.getStdOut().writer();

    const index = try Index.loadOrBuild(allocator, config.cache);
    const cellar = Cellar.init(config.cellar);
    const installed = try cellar.installedFormulae(allocator);
    defer {
        for (installed) |f| {
            for (f.versions) |v| allocator.free(v);
            allocator.free(f.versions);
            allocator.free(f.name);
        }
        allocator.free(installed);
    }

    // Build set of all deps of installed formulae
    var dep_set = std.StringHashMap(void).init(allocator);
    defer dep_set.deinit();

    for (installed) |f| {
        const entry = index.lookup(f.name) orelse continue;
        const deps = index.getStringList(allocator, entry.deps_offset) catch continue;
        defer allocator.free(deps);
        for (deps) |d| {
            try dep_set.put(d, {});
        }
    }

    // Print installed formulae not in dep set
    for (installed) |f| {
        if (dep_set.contains(f.name)) continue;
        // Check if installed_on_request via tab
        var keg_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const keg_path = std.fmt.bufPrint(&keg_path_buf, "{s}/{s}/{s}", .{
            config.cellar, f.name, f.latestVersion(),
        }) catch continue;
        var tab = (Tab.loadFromKeg(allocator, keg_path) catch continue) orelse continue;
        defer tab.deinit(allocator);
        if (tab.installed_on_request) {
            try stdout.print("{s}\n", .{f.name});
        }
    }
}
```

**Step 2: Register in dispatch.zig**

```zig
const leaves = @import("cmd/leaves.zig");
.{ "leaves", leaves.leavesCmd },
```

**Step 3: Build and test**

Run: `zig build run -- leaves`
Compare: `diff <(zig build run -- leaves 2>/dev/null) <(brew leaves 2>/dev/null)`

**Step 4: Commit**

```bash
git add src/cmd/leaves.zig src/dispatch.zig
git commit -m "feat: leaves command identifies non-dependency installed formulae"
```

---

### Task 19: `config` Command

**Files:**
- Create: `src/cmd/config_cmd.zig`
- Modify: `src/dispatch.zig`

**Context:** `brew config` displays system info: macOS version, Xcode, CPU, Homebrew prefix, etc. We output the same format.

**Step 1: Create src/cmd/config_cmd.zig**

```zig
const std = @import("std");
const Config = @import("../config.zig").Config;

pub fn configCmd(allocator: std.mem.Allocator, _: []const []const u8, config: Config) !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print("HOMEBREW_VERSION: bru 0.1.0 (brew compat)\n", .{});
    try stdout.print("ORIGIN: https://github.com/user/bru\n", .{});
    try stdout.print("HOMEBREW_PREFIX: {s}\n", .{config.prefix});
    try stdout.print("HOMEBREW_CELLAR: {s}\n", .{config.cellar});
    try stdout.print("HOMEBREW_CASKROOM: {s}\n", .{config.caskroom});
    try stdout.print("HOMEBREW_CACHE: {s}\n", .{config.cache});

    // System info
    const builtin = @import("builtin");
    try stdout.print("CPU: {s}\n", .{@tagName(builtin.cpu.arch)});
    try stdout.print("OS: {s}\n", .{@tagName(builtin.os.tag)});

    // Try to get macOS version
    if (builtin.os.tag == .macos) {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "sw_vers", "-productVersion" },
        }) catch {
            try stdout.print("macOS: unknown\n", .{});
            return;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        const version = std.mem.trim(u8, result.stdout, "\n\r ");
        try stdout.print("macOS: {s}\n", .{version});
    }
}
```

**Step 2: Register in dispatch.zig**

```zig
const config_cmd = @import("cmd/config_cmd.zig");
.{ "config", config_cmd.configCmd },
```

**Step 3: Build and test**

Run: `zig build run -- config`
Expected: System config info

**Step 4: Commit**

```bash
git add src/cmd/config_cmd.zig src/dispatch.zig
git commit -m "feat: config command displays system info"
```

---

## Phase 5: Polish & Validation (Task 20)

### Task 20: End-to-End Validation & Compat Test Script

**Files:**
- Create: `test/compat/compare.sh`

**Context:** Create a script that compares bru output against brew output for all implemented commands. This is our regression safety net.

**Step 1: Create test/compat/compare.sh**

```bash
#!/bin/bash
set -e

BRU="./zig-out/bin/bru"
PASS=0
FAIL=0

compare() {
    local cmd="$1"
    local bru_out brew_out
    bru_out=$($BRU $cmd 2>/dev/null | sort) || true
    brew_out=$(brew $cmd 2>/dev/null | sort) || true

    if [ "$bru_out" = "$brew_out" ]; then
        echo "PASS: $cmd"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $cmd"
        diff <(echo "$bru_out") <(echo "$brew_out") | head -10
        FAIL=$((FAIL + 1))
    fi
}

echo "Building bru..."
zig build -Doptimize=ReleaseFast

echo ""
echo "=== Comparing bru vs brew ==="
echo ""

compare "--prefix"
compare "--cellar"
compare "--cache"
compare "--version"
compare "list"
compare "list --versions"
compare "leaves"
compare "outdated"
compare "search bat"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
```

**Step 2: Run the script**

Run: `bash test/compat/compare.sh`
Expected: Most tests pass. Fix any discrepancies found.

**Step 3: Commit**

```bash
git add test/compat/compare.sh
git commit -m "feat: compat test script comparing bru vs brew output"
```

---

## Summary

| Phase | Tasks | What it delivers |
|-------|-------|-----------------|
| 1: Foundation | 1–6 | Build system, config, dispatch, fallback, output, version |
| 2: Cellar & First Commands | 7–10 | Cellar scanner, --prefix/--cellar/--cache, list, tab reader |
| 3: Binary Index | 11–13 | JSON parser, index builder, mmap I/O |
| 4: Tier 1 Commands | 14–19 | search, info, outdated, deps, leaves, config |
| 5: Polish | 20 | Compat test script |

After this plan: bru handles 10+ commands natively with index-backed O(1) lookups, falls back to brew for everything else, and has a compat test suite verifying output matches brew.
