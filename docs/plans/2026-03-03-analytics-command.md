# `analytics` Command Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement native `bru analytics [state|on|off|regenerate-uuid]` command for managing Homebrew analytics state, replacing the fallback to `brew analytics`.

**Architecture:** Single command file `src/cmd/analytics.zig` that reads/writes `homebrew.analyticsdisabled` in the Homebrew repository's local git config via `git config --local`. The `HOMEBREW_NO_ANALYTICS` env var overrides git config. `regenerate-uuid` matches modern brew behavior (prints deprecation warning, deletes UUID file if present, exits 1).

**Tech Stack:** Zig 0.15.2, spawns `git` subprocess for config read/write, direct filesystem for UUID file operations.

---

### Task 1: Create analytics.zig with signature test

**Files:**
- Create: `src/cmd/analytics.zig`

**Step 1: Write the test file with signature test**

Create `src/cmd/analytics.zig` with:

```zig
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
    _ = allocator;
    _ = args;
    _ = config;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "analyticsCmd compiles and has correct signature" {
    const handler: @import("../dispatch.zig").CommandFn = analyticsCmd;
    _ = handler;
}
```

**Step 2: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS (the signature test validates the function type)

**Step 3: Commit**

```bash
git add src/cmd/analytics.zig
git commit -m "feat(analytics): scaffold command with signature test"
```

---

### Task 2: Register in dispatch, main, and help

**Files:**
- Modify: `src/dispatch.zig` (lines 1-88)
- Modify: `src/main.zig` (lines 90-140)
- Modify: `src/help.zig` (lines 72-336, and lines 342-361)

**Step 1: Add import and dispatch entry**

In `src/dispatch.zig`, add import after the `formulae` import (line 29):

```zig
const analytics = @import("cmd/analytics.zig");
```

Add entry to `native_commands` array after the `formulae` entry (line 87):

```zig
    .{ .name = "analytics", .handler = analytics.analyticsCmd },
```

**Step 2: Add test import in main.zig**

In `src/main.zig`, add after the `tap.zig` import (line 118):

```zig
    _ = @import("cmd/analytics.zig");
```

**Step 3: Add help entry**

In `src/help.zig`, add to the `getCommandHelp` entries (after the `tap` entry, before the closing `};`):

```zig
        .{ "analytics",
            \\Usage: bru analytics [subcommand]
            \\
            \\Manage Homebrew's anonymous aggregate user analytics.
            \\
            \\Subcommands:
            \\  state              Show current analytics status (default)
            \\  on                 Enable analytics
            \\  off                Disable analytics
            \\  regenerate-uuid    Deprecated (no longer necessary)
            \\
        },
```

Add `"analytics"` to the general help text under "Maintenance commands" section (after the `commands` line):

```
            \\  analytics  Manage anonymous aggregate user analytics
```

Add `"analytics"` to the `getCommandHelp returns help for known commands` test:

```zig
    try std.testing.expect(getCommandHelp("analytics") != null);
```

**Step 4: Run tests**

Run: `zig build test 2>&1 | tail -20`
Expected: All PASS

**Step 5: Commit**

```bash
git add src/dispatch.zig src/main.zig src/help.zig
git commit -m "feat(analytics): register command in dispatch, help, and test imports"
```

---

### Task 3: Implement `state` subcommand (default behavior)

**Files:**
- Modify: `src/cmd/analytics.zig`

**Step 1: Write tests for analytics state reading**

Add to `src/cmd/analytics.zig`:

```zig
test "isAnalyticsDisabledByEnv returns false when env not set" {
    // In test environment HOMEBREW_NO_ANALYTICS is typically not set.
    // This test verifies the env check path works.
    const result = isAnalyticsDisabledByEnv();
    // We can't control env in unit tests easily, so just verify it compiles
    // and returns a bool.
    _ = result;
}
```

**Step 2: Implement the state logic**

Replace the `analyticsCmd` function body and add helpers:

```zig
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
        try setAnalyticsConfig(allocator, config.repository, false);
        return;
    }

    if (std.mem.eql(u8, subcommand, "off")) {
        try setAnalyticsConfig(allocator, config.repository, true);
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
    }) catch |e| {
        const err_out = Output.initErr(false);
        err_out.err("Could not update analytics config: {s}", .{@errorName(e)});
        std.process.exit(1);
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    if (result.term.Exited != 0) {
        const err_out = Output.initErr(false);
        err_out.err("git config failed.", .{});
        std.process.exit(1);
    }
}

/// Delete the analytics UUID file if it exists.
fn deleteUuidFile(repository: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/.homebrew_analytics_user_uuid", .{repository}) catch return;
    std.fs.cwd().deleteFile(path) catch {};
}
```

**Step 3: Run tests**

Run: `zig build test 2>&1 | tail -20`
Expected: All PASS

**Step 4: Commit**

```bash
git add src/cmd/analytics.zig
git commit -m "feat(analytics): implement state, on, off, and regenerate-uuid subcommands"
```

---

### Task 4: Manual integration test

**Step 1: Build and test**

```bash
zig build
```

**Step 2: Test each subcommand**

```bash
./zig-out/bin/bru analytics
# Expected: "InfluxDB analytics are enabled." (or disabled) + "Google Analytics were destroyed."

./zig-out/bin/bru analytics state
# Expected: Same as above

./zig-out/bin/bru analytics off
# Expected: No output, exit 0

./zig-out/bin/bru analytics
# Expected: "InfluxDB analytics are disabled." + "Google Analytics were destroyed."

./zig-out/bin/bru analytics on
# Expected: No output, exit 0

./zig-out/bin/bru analytics
# Expected: "InfluxDB analytics are enabled." + "Google Analytics were destroyed."

./zig-out/bin/bru analytics regenerate-uuid
# Expected: Warning message, exit 1

./zig-out/bin/bru analytics --help
# Expected: Help text

./zig-out/bin/bru analytics bogus
# Expected: Error: Unknown analytics subcommand: bogus

HOMEBREW_NO_ANALYTICS=1 ./zig-out/bin/bru analytics
# Expected: "InfluxDB analytics are disabled." regardless of git config
```

**Step 3: Restore original analytics state**

```bash
# If analytics were originally enabled:
./zig-out/bin/bru analytics on
```

**Step 4: Commit (if any fixes needed)**

Only if manual testing revealed issues that needed fixing.

---

### Task 5: Final commit and cleanup

**Step 1: Run full test suite**

```bash
zig build test 2>&1
```
Expected: All PASS

**Step 2: Verify clean git status**

```bash
git status
git log --oneline -5
```

All changes should be committed. Branch ready for PR.
