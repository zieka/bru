# Native `completions` Command Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement a native `bru completions` command that manages shell completion scripts (state/link/unlink) without falling back to brew.

**Architecture:** Embed the static completion scripts (`completions/bru.{bash,zsh,fish}`) into the binary at comptime via `@embedFile`. The `link` subcommand writes them to shell-specific directories under `{prefix}`. The `state` subcommand checks if those files exist. The `unlink` subcommand removes them.

**Tech Stack:** Zig, `@embedFile` for comptime embedding, `std.fs` for file operations.

---

### Task 1: Create `src/cmd/completions.zig` with embedded scripts and subcommand dispatch

**Files:**
- Create: `src/cmd/completions.zig`

**Step 1: Write the failing test**

Create `src/cmd/completions.zig` with only the test:

```zig
const std = @import("std");
const Config = @import("../config.zig").Config;

// Embedded completion scripts (comptime).
const bash_completion = @embedFile("../../completions/bru.bash");
const zsh_completion = @embedFile("../../completions/bru.zsh");
const fish_completion = @embedFile("../../completions/bru.fish");

pub fn completionsCmd(allocator: std.mem.Allocator, args: []const []const u8, config: Config) anyerror!void {
    _ = allocator;
    _ = args;
    _ = config;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "completionsCmd compiles and has correct signature" {
    const handler: @import("../dispatch.zig").CommandFn = completionsCmd;
    _ = handler;
}

test "embedded completion scripts are non-empty" {
    try std.testing.expect(bash_completion.len > 0);
    try std.testing.expect(zsh_completion.len > 0);
    try std.testing.expect(fish_completion.len > 0);
}
```

**Step 2: Run test to verify it compiles and passes**

Run: `zig build test`
Expected: PASS (skeleton + embed test)

**Step 3: Implement the full command**

Replace `completionsCmd` with the full implementation:

```zig
const std = @import("std");
const Config = @import("../config.zig").Config;
const Output = @import("../output.zig").Output;

// Embedded completion scripts (comptime).
const bash_completion = @embedFile("../../completions/bru.bash");
const zsh_completion = @embedFile("../../completions/bru.zsh");
const fish_completion = @embedFile("../../completions/bru.fish");

const Shell = enum { bash, zsh, fish };

const shell_targets = [_]struct {
    shell: Shell,
    /// Format string: {s} is replaced with config.prefix.
    dir_fmt: []const u8,
    filename: []const u8,
    content: []const u8,
}{
    .{ .shell = .bash, .dir_fmt = "{s}/etc/bash_completion.d", .filename = "bru", .content = bash_completion },
    .{ .shell = .zsh, .dir_fmt = "{s}/share/zsh/site-functions", .filename = "_bru", .content = zsh_completion },
    .{ .shell = .fish, .dir_fmt = "{s}/share/fish/vendor_completions.d", .filename = "bru.fish", .content = fish_completion },
};

pub fn completionsCmd(_: std.mem.Allocator, args: []const []const u8, config: Config) anyerror!void {
    const out = Output.init(config.no_color);
    const err_out = Output.initErr(config.no_color);

    // Find first positional arg (skip flags).
    var subcmd: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) continue;
        subcmd = arg;
        break;
    }

    const cmd = subcmd orelse "state";

    if (std.mem.eql(u8, cmd, "state")) {
        return showState(out, config.prefix);
    } else if (std.mem.eql(u8, cmd, "link")) {
        return doLink(out, err_out, config.prefix);
    } else if (std.mem.eql(u8, cmd, "unlink")) {
        return doUnlink(out, config.prefix);
    } else {
        err_out.err("Unknown subcommand: {s}", .{cmd});
        err_out.print("Usage: bru completions [state|link|unlink]", .{});
        std.process.exit(1);
    }
}

fn showState(out: Output, prefix: []const u8) void {
    var all_linked = true;
    for (shell_targets) |target| {
        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = std.fmt.bufPrint(&dir_buf, target.dir_fmt, .{prefix}) catch continue;

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, target.filename }) catch continue;

        const exists = fileExists(path);
        if (!exists) all_linked = false;
    }

    if (all_linked) {
        out.print("Completions are linked.\n", .{});
    } else {
        out.print("Completions are not linked.\n", .{});
    }
}

fn doLink(out: Output, err_out: Output, prefix: []const u8) void {
    for (shell_targets) |target| {
        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = std.fmt.bufPrint(&dir_buf, target.dir_fmt, .{prefix}) catch {
            err_out.err("Path too long.", .{});
            std.process.exit(1);
        };

        // Create the directory if it doesn't exist.
        makeDirRecursive(dir) catch {
            err_out.err("Could not create directory: {s}", .{dir});
            std.process.exit(1);
        };

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, target.filename }) catch {
            err_out.err("Path too long.", .{});
            std.process.exit(1);
        };

        // Write the file (overwrites if already present).
        const cwd = std.fs.cwd();
        const file = cwd.createFile(path, .{}) catch {
            err_out.err("Could not write {s}", .{path});
            std.process.exit(1);
        };
        defer file.close();
        file.writeAll(target.content) catch {
            err_out.err("Could not write {s}", .{path});
            std.process.exit(1);
        };
    }

    out.print("Completions linked successfully.\n", .{});
}

fn doUnlink(out: Output, prefix: []const u8) void {
    for (shell_targets) |target| {
        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = std.fmt.bufPrint(&dir_buf, target.dir_fmt, .{prefix}) catch continue;

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, target.filename }) catch continue;

        std.fs.cwd().deleteFile(path) catch {};
    }

    out.print("Completions unlinked.\n", .{});
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Recursively create directories for a path.
fn makeDirRecursive(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |e| switch (e) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            const parent = std.fs.path.dirname(path) orelse return e;
            try makeDirRecursive(parent);
            std.fs.makeDirAbsolute(path) catch |e2| switch (e2) {
                error.PathAlreadyExists => return,
                else => return e2,
            };
        },
        else => return e,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "completionsCmd compiles and has correct signature" {
    const handler: @import("../dispatch.zig").CommandFn = completionsCmd;
    _ = handler;
}

test "embedded completion scripts are non-empty" {
    try std.testing.expect(bash_completion.len > 0);
    try std.testing.expect(zsh_completion.len > 0);
    try std.testing.expect(fish_completion.len > 0);
}

test "fileExists returns false for nonexistent path" {
    try std.testing.expect(!fileExists("/nonexistent/__bru_test_xyz__"));
}
```

**Step 4: Run tests to verify**

Run: `zig build test`
Expected: PASS

**Step 5: Commit**

```bash
git add src/cmd/completions.zig
git commit -m "feat: add completions command with embedded shell scripts"
```

---

### Task 2: Register in dispatch table, help text, and test imports

**Files:**
- Modify: `src/dispatch.zig` (add import + table entry)
- Modify: `src/help.zig` (add help text + general help entry)
- Modify: `src/main.zig` (add test import)

**Step 1: Add import and dispatch entry in `src/dispatch.zig`**

After the `formulae` import (line 29), add:
```zig
const completions = @import("cmd/completions.zig");
```

In `native_commands` array, after the `formulae` entry (line 87), add:
```zig
.{ .name = "completions", .handler = completions.completionsCmd },
```

**Step 2: Add help text in `src/help.zig`**

In the general help text, add under "Environment commands:" section:
```
\\  completions Print or manage shell completion scripts
```

In `getCommandHelp` entries, after the `tap` entry, add:
```zig
.{ "completions",
    \\Usage: bru completions [state|link|unlink]
    \\
    \\Control whether bru automatically links shell completion files.
    \\
    \\bru completions [state]:
    \\    Display the current state of bru's completions.
    \\
    \\bru completions link:
    \\    Write completion scripts into shell completion directories.
    \\
    \\bru completions unlink:
    \\    Remove completion scripts from shell completion directories.
    \\
},
```

Also add `"completions"` to the `getCommandHelp returns help for known commands` test.

**Step 3: Add test import in `src/main.zig`**

In the test block, after the `tap` import, add:
```zig
_ = @import("cmd/completions.zig");
```

**Step 4: Run all tests**

Run: `zig build test`
Expected: PASS

**Step 5: Commit**

```bash
git add src/dispatch.zig src/help.zig src/main.zig
git commit -m "feat: register completions command in dispatch, help, and tests"
```

---

### Task 3: Verify end-to-end behavior

**Step 1: Build and test CLI**

```bash
zig build
```

**Step 2: Test `state` subcommand**

```bash
./zig-out/bin/bru completions state
```
Expected: "Completions are linked." or "Completions are not linked."

**Step 3: Test `--help`**

```bash
./zig-out/bin/bru completions --help
```
Expected: Shows the help text from help.zig

**Step 4: Test unknown subcommand**

```bash
./zig-out/bin/bru completions foo 2>&1; echo "exit: $?"
```
Expected: Error message about unknown subcommand, exit code 1

**Step 5: Final commit (if any fixes needed)**

Only commit if fixes were needed from the verification steps.
