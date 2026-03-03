# Native `migrate` Command Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement `bru migrate <formula>` as a native command that handles formula renames natively and falls back to brew for deprecation replacements and tap migrations.

**Architecture:** Extend the formula index with `oldnames` and `deprecation_replacement` fields plus a secondary hash table for reverse oldname→entry lookups. Add a tap migrations parser for `formula_tap_migrations.jws.json`. The migrate command resolves the migration type and either performs a native rename (unlink→rename cellar dir→relink) or falls back to `brew migrate`.

**Tech Stack:** Zig, binary index format, JWS JSON parsing, filesystem operations

---

### Task 1: Add `oldnames` and `deprecation_replacement` to FormulaInfo

**Files:**
- Modify: `src/formula.zig`

**Step 1: Add fields to FormulaInfo struct**

In `src/formula.zig`, add two fields to `FormulaInfo` after `build_dependencies`:

```zig
    oldnames: []const []const u8,
    deprecation_replacement: []const u8,
```

**Step 2: Parse the new fields in `parseOneFormula`**

After the `build_dependencies` parsing (line 133), add:

```zig
    const oldnames = try parseStringArray(allocator, obj, "oldnames");
    errdefer freeStringSlice(allocator, oldnames);

    const deprecation_replacement = try allocator.dupe(u8, jsonStr(obj, "deprecation_replacement_formula") orelse "");
```

Add these to the return struct:

```zig
        .oldnames = oldnames,
        .deprecation_replacement = deprecation_replacement,
```

**Step 3: Free the new fields in `freeFormula`**

Add to `freeFormula`:

```zig
    freeStringSlice(allocator, f.oldnames);
    allocator.free(f.deprecation_replacement);
```

**Step 4: Update existing tests**

Update the test `"parseFormulaJson parses small payload"` JSON to include the new fields:

Add to the JSON object:
```json
"oldnames": [],
"deprecation_replacement_formula": null
```

Update the `"build and lookup"` test in `src/index.zig` and the `"loadOrBuild"` tests — add the new fields to any `FormulaInfo` literals:

```zig
        .oldnames = &.{},
        .deprecation_replacement = "",
```

**Step 5: Add a test for parsing oldnames**

```zig
test "parseFormulaJson parses oldnames and replacement" {
    const allocator = std.testing.allocator;

    const json_bytes =
        \\[{
        \\  "name": "adwaita-icon-theme",
        \\  "full_name": "adwaita-icon-theme",
        \\  "tap": "homebrew/core",
        \\  "desc": "Icons for GNOME",
        \\  "homepage": "https://gnome.org",
        \\  "license": "LGPL-3.0",
        \\  "versions": {"stable": "46.0", "head": null},
        \\  "revision": 0,
        \\  "keg_only": false,
        \\  "deprecated": false,
        \\  "disabled": false,
        \\  "caveats": null,
        \\  "dependencies": [],
        \\  "build_dependencies": [],
        \\  "oldnames": ["gnome-icon-theme"],
        \\  "deprecation_replacement_formula": null,
        \\  "bottle": {}
        \\}]
    ;

    const formulae = try parseFormulaJson(allocator, json_bytes);
    defer {
        for (formulae) |f| freeFormula(allocator, f);
        allocator.free(formulae);
    }

    try std.testing.expectEqual(@as(usize, 1), formulae.len);
    try std.testing.expectEqual(@as(usize, 1), formulae[0].oldnames.len);
    try std.testing.expectEqualStrings("gnome-icon-theme", formulae[0].oldnames[0]);
    try std.testing.expectEqualStrings("", formulae[0].deprecation_replacement);
}
```

**Step 6: Run tests to verify**

Run: `zig build test 2>&1 | head -5`
Expected: `Build Summary: 1/1 Test Modules passed.`

**Step 7: Commit**

```bash
git add src/formula.zig src/index.zig
git commit -m "feat(migrate): add oldnames and deprecation_replacement to FormulaInfo"
```

---

### Task 2: Extend IndexEntry and build secondary oldnames hash table

**Files:**
- Modify: `src/index.zig`

**Step 1: Add fields to IndexEntry**

Add after `bottle_cellar_offset`:

```zig
    oldnames_offset: u32 = 0,
    replacement_offset: u32 = 0,
```

**Step 2: Add `oldname_hash_table_offset` to IndexHeader**

Add after `strings_offset`:

```zig
    oldname_hash_table_offset: u64 = 0,
```

**Step 3: Bump index version**

Change `IndexHeader.version` default from `2` to `3`.

Change the version check in `openFromDisk` (line 354) from `ver != 2` to `ver != 3`.

**Step 4: Build oldnames into IndexEntry during `Index.build`**

In the entry-building loop (inside `for (formulae, 0..) |f, i|`), add:

```zig
                .oldnames_offset = try stb.addStringList(allocator, f.oldnames),
                .replacement_offset = try stb.addString(allocator, f.deprecation_replacement),
```

**Step 5: Build the secondary oldnames hash table**

After the existing hash table insertion loop (after line 174), add code to build a second hash table for oldnames. Count total oldnames first, then build the table:

```zig
        // ------------------------------------------------------------------
        // 2b. Build oldnames hash table (oldname -> entry_index).
        // ------------------------------------------------------------------
        var total_oldnames: u32 = 0;
        for (formulae) |f| {
            total_oldnames += @intCast(f.oldnames.len);
        }

        const old_bucket_count: u32 = if (total_oldnames == 0) 2 else total_oldnames * 2;
        const old_hash_table = try allocator.alloc(HashBucket, old_bucket_count);
        defer allocator.free(old_hash_table);

        for (old_hash_table) |*b| {
            b.* = HashBucket{};
        }

        for (formulae, 0..) |f, i| {
            for (f.oldnames) |oldname| {
                const oh = fnvHash(oldname);
                var oslot = oh % old_bucket_count;
                while (old_hash_table[oslot].entry_index != std.math.maxInt(u32)) {
                    oslot = (oslot + 1) % old_bucket_count;
                }
                old_hash_table[oslot] = HashBucket{
                    .string_offset = try stb.addString(allocator, oldname),
                    .entry_index = @intCast(i),
                };
            }
        }
```

**Step 6: Update layout calculation**

Update the layout section to include the oldnames hash table. The old hash table goes after the string table:

```zig
        const old_hash_table_size: u64 = @as(u64, old_bucket_count) * @sizeOf(HashBucket);

        const hash_table_offset = header_size;
        const entries_offset = hash_table_offset + hash_table_size;
        const strings_offset = entries_offset + entries_size;
        const oldname_ht_offset = strings_offset + strings_size;
        const total_size: usize = @intCast(oldname_ht_offset + old_hash_table_size);
```

Update the header:

```zig
            .strings_offset = strings_offset,
            .oldname_hash_table_offset = oldname_ht_offset,
```

Copy the oldnames hash table into the buffer:

```zig
        // Oldnames hash table
        const oht_bytes = mem.sliceAsBytes(old_hash_table);
        @memcpy(buf[@intCast(oldname_ht_offset)..][0..oht_bytes.len], oht_bytes);
```

**Step 7: Add `lookupByOldname` method**

Add to the `Index` struct, after the `lookup` method:

```zig
    /// Look up a formula by one of its old names. Returns the IndexEntry if found.
    pub fn lookupByOldname(self: *const Index, oldname: []const u8) ?IndexEntry {
        const header = self.getHeader();
        if (header.oldname_hash_table_offset == 0) return null;

        // Compute bucket count from the space between oldname_hash_table_offset and end of data.
        const oht_size = self.data.len - @as(usize, @intCast(header.oldname_hash_table_offset));
        const old_bucket_count: u32 = @intCast(oht_size / @sizeOf(HashBucket));
        if (old_bucket_count == 0) return null;

        const h = fnvHash(oldname);
        var slot = h % old_bucket_count;

        while (true) {
            const bucket_off: usize = @intCast(header.oldname_hash_table_offset + @as(u64, slot) * @sizeOf(HashBucket));
            const bucket = mem.bytesToValue(HashBucket, self.data[bucket_off..][0..@sizeOf(HashBucket)]);
            if (bucket.entry_index == std.math.maxInt(u32)) {
                return null;
            }
            const candidate = self.getString(bucket.string_offset);
            if (mem.eql(u8, candidate, oldname)) {
                return self.getEntryByIndex(bucket.entry_index);
            }
            slot = (slot + 1) % old_bucket_count;
        }
    }
```

**Step 8: Update existing tests**

Update all `FormulaInfo` literals in `src/index.zig` tests to include:

```zig
        .oldnames = &.{},
        .deprecation_replacement = "",
```

**Step 9: Add test for lookupByOldname**

```zig
test "lookupByOldname finds renamed formula" {
    const allocator = std.testing.allocator;

    const old = [_][]const u8{"gnome-icon-theme"};
    const formula = FormulaInfo{
        .name = "adwaita-icon-theme",
        .full_name = "adwaita-icon-theme",
        .desc = "Icons for GNOME",
        .homepage = "",
        .license = "",
        .version = "46.0",
        .revision = 0,
        .tap = "homebrew/core",
        .keg_only = false,
        .deprecated = false,
        .disabled = false,
        .has_head = false,
        .caveats = "",
        .dependencies = &.{},
        .build_dependencies = &.{},
        .bottle_root_url = "",
        .bottle_sha256 = "",
        .bottle_cellar = "",
        .oldnames = &old,
        .deprecation_replacement = "",
    };

    const formulae = [_]FormulaInfo{formula};
    var idx = try Index.build(allocator, &formulae);
    defer idx.deinit();

    // Lookup by old name should find the entry.
    const entry = idx.lookupByOldname("gnome-icon-theme") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("adwaita-icon-theme", idx.getString(entry.name_offset));

    // Lookup by current name should still work.
    const entry2 = idx.lookup("adwaita-icon-theme") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("adwaita-icon-theme", idx.getString(entry2.name_offset));

    // Lookup by old name should NOT find via the main lookup.
    try std.testing.expect(idx.lookup("gnome-icon-theme") == null);

    // Lookup by nonexistent old name should return null.
    try std.testing.expect(idx.lookupByOldname("nonexistent") == null);
}
```

**Step 10: Run tests**

Run: `zig build test 2>&1 | head -5`
Expected: `Build Summary: 1/1 Test Modules passed.`

**Step 11: Commit**

```bash
git add src/index.zig
git commit -m "feat(migrate): extend index with oldnames hash table and lookupByOldname"
```

---

### Task 3: Create tap migrations parser

**Files:**
- Create: `src/tap_migrations.zig`
- Modify: `src/main.zig` (test reference)

**Step 1: Create `src/tap_migrations.zig`**

```zig
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

/// Parsed tap migration target.
pub const MigrationTarget = struct {
    /// Full target string, e.g. "homebrew/cask" or "homebrew/cask/luanti".
    raw: []const u8,

    /// Returns true if the target is a cask (starts with "homebrew/cask").
    pub fn isCask(self: MigrationTarget) bool {
        return mem.startsWith(u8, self.raw, "homebrew/cask");
    }

    /// Extract the new name from the target.
    /// - "homebrew/cask/luanti" -> "luanti"
    /// - "homebrew/cask" -> null (same name, just moved to cask)
    /// - "some-tap/some-name" -> "some-name"
    pub fn newName(self: MigrationTarget) ?[]const u8 {
        // Count slashes: "homebrew/cask" has 1, "homebrew/cask/luanti" has 2
        var slash_count: usize = 0;
        var last_slash: usize = 0;
        for (self.raw, 0..) |c, i| {
            if (c == '/') {
                slash_count += 1;
                last_slash = i;
            }
        }
        // "homebrew/cask" (1 slash) -> no rename, just moved
        if (slash_count <= 1) return null;
        // "homebrew/cask/luanti" (2 slashes) -> "luanti"
        if (last_slash + 1 < self.raw.len) return self.raw[last_slash + 1 ..];
        return null;
    }
};

/// Loads and queries formula tap migrations from the Homebrew API cache.
pub const TapMigrations = struct {
    parsed: std.json.Parsed(std.json.Value),

    /// Load tap migrations from {cache}/api/formula_tap_migrations.jws.json.
    /// Returns null if the file doesn't exist or can't be parsed.
    pub fn load(allocator: Allocator, cache_dir: []const u8) ?TapMigrations {
        var path_buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/api/formula_tap_migrations.jws.json", .{cache_dir}) catch return null;

        const file = std.fs.openFileAbsolute(path, .{}) catch return null;
        defer file.close();

        const bytes = file.readToEndAlloc(allocator, 4 * 1024 * 1024) catch return null;
        defer allocator.free(bytes);

        // Parse outer JWS envelope.
        const jws = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
            .allocate = .alloc_always,
        }) catch return null;

        const payload_str = switch (jws.value) {
            .object => |obj| switch (obj.get("payload") orelse {
                jws.deinit();
                return null;
            }) {
                .string => |s| s,
                else => {
                    jws.deinit();
                    return null;
                },
            },
            else => {
                jws.deinit();
                return null;
            },
        };

        // Parse the payload string as a JSON object.
        const migrations = std.json.parseFromSlice(std.json.Value, allocator, payload_str, .{
            .allocate = .alloc_always,
        }) catch {
            jws.deinit();
            return null;
        };

        // We keep the migrations parsed value; free the JWS envelope.
        jws.deinit();

        return TapMigrations{
            .parsed = migrations,
        };
    }

    /// Look up a formula name in the tap migrations.
    pub fn lookup(self: *const TapMigrations, name: []const u8) ?MigrationTarget {
        const obj = switch (self.parsed.value) {
            .object => |o| o,
            else => return null,
        };
        const val = obj.get(name) orelse return null;
        return switch (val) {
            .string => |s| MigrationTarget{ .raw = s },
            else => null,
        };
    }

    pub fn deinit(self: *TapMigrations) void {
        self.parsed.deinit();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "MigrationTarget.isCask" {
    const cask = MigrationTarget{ .raw = "homebrew/cask" };
    try std.testing.expect(cask.isCask());

    const cask_named = MigrationTarget{ .raw = "homebrew/cask/luanti" };
    try std.testing.expect(cask_named.isCask());

    const formula = MigrationTarget{ .raw = "homebrew/core" };
    try std.testing.expect(!formula.isCask());
}

test "MigrationTarget.newName" {
    const same_name = MigrationTarget{ .raw = "homebrew/cask" };
    try std.testing.expect(same_name.newName() == null);

    const renamed = MigrationTarget{ .raw = "homebrew/cask/luanti" };
    try std.testing.expectEqualStrings("luanti", renamed.newName().?);

    const tap_move = MigrationTarget{ .raw = "some-tap/some-formula" };
    try std.testing.expect(tap_move.newName() == null);
}

test "TapMigrations load from real cache" {
    const allocator = std.testing.allocator;

    const home = std.posix.getenv("HOME") orelse return;
    var buf: [512]u8 = undefined;
    const cache_dir = std.fmt.bufPrint(&buf, "{s}/Library/Caches/Homebrew", .{home}) catch return;

    var migrations = TapMigrations.load(allocator, cache_dir) orelse return;
    defer migrations.deinit();

    // The tap migrations file should exist and have entries.
    // Check for a known migration (these are stable).
    if (migrations.lookup("android-ndk")) |target| {
        try std.testing.expect(target.isCask());
    }
}
```

**Step 2: Add test reference in main.zig**

Add to the `test` block in `src/main.zig`:

```zig
    _ = @import("tap_migrations.zig");
```

**Step 3: Run tests**

Run: `zig build test 2>&1 | head -5`
Expected: `Build Summary: 1/1 Test Modules passed.`

**Step 4: Commit**

```bash
git add src/tap_migrations.zig src/main.zig
git commit -m "feat(migrate): add tap migrations parser"
```

---

### Task 4: Implement the migrate command

**Files:**
- Create: `src/cmd/migrate.zig`
- Modify: `src/dispatch.zig`
- Modify: `src/main.zig`

**Step 1: Create `src/cmd/migrate.zig`**

```zig
const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;
const Config = @import("../config.zig").Config;
const Cellar = @import("../cellar.zig").Cellar;
const Linker = @import("../linker.zig").Linker;
const Output = @import("../output.zig").Output;
const Index = @import("../index.zig").Index;
const TapMigrations = @import("../tap_migrations.zig").TapMigrations;
const fallback = @import("../fallback.zig");
const pin_mod = @import("pin.zig");

/// Migrate renamed or deprecated formulae to their replacements.
///
/// Usage: bru migrate [--force] [--dry-run/-n] [--formula] [--cask] <formula> [...]
pub fn migrateCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    const out = Output.init(config.no_color);
    const err_out = Output.initErr(config.no_color);

    // Parse flags and formula names.
    var names: std.ArrayList([]const u8) = .{};
    defer names.deinit(allocator);

    var dry_run = false;
    var force = false;
    var formula_only = false;
    var cask_only = false;

    for (args) |arg| {
        if (mem.eql(u8, arg, "--dry-run") or mem.eql(u8, arg, "-n")) {
            dry_run = true;
        } else if (mem.eql(u8, arg, "--force") or mem.eql(u8, arg, "-f")) {
            force = true;
        } else if (mem.eql(u8, arg, "--formula") or mem.eql(u8, arg, "--formulae")) {
            formula_only = true;
        } else if (mem.eql(u8, arg, "--cask") or mem.eql(u8, arg, "--casks")) {
            cask_only = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            continue;
        } else {
            try names.append(allocator, arg);
        }
    }

    if (names.items.len == 0) {
        err_out.err("This command requires at least one installed formula or cask argument.", .{});
        std.process.exit(1);
    }

    _ = force; // Used by fallback args passthrough
    _ = formula_only;
    _ = cask_only;

    const cellar = Cellar.init(config.cellar);

    // Load the formula index.
    var idx = Index.loadOrBuild(allocator, config.cache) catch {
        err_out.err("Could not load formula index.", .{});
        std.process.exit(1);
    };
    defer idx.deinit();

    // Load tap migrations (optional — may not exist).
    var tap_migrations = TapMigrations.load(allocator, config.cache);
    defer if (tap_migrations) |*tm| tm.deinit();

    for (names.items) |name| {
        // 1. Check if installed.
        if (!cellar.isInstalled(name)) {
            err_out.err("{s} is not installed.", .{name});
            std.process.exit(1);
        }

        // 2. Check tap migrations first — these require fallback to brew.
        if (tap_migrations) |*tm| {
            if (tm.lookup(name)) |_| {
                // Tap migration detected — fall back to brew for this.
                out.print("==> {s} has been migrated to a different tap.\n", .{name});
                out.print("Falling back to brew migrate...\n", .{});
                fallbackToBrew(allocator, args);
            }
        }

        // 3. Check reverse lookup (old name -> new formula).
        if (idx.lookupByOldname(name)) |entry| {
            const new_name = idx.getString(entry.name_offset);

            // Check if the new name is already installed.
            if (cellar.isInstalled(new_name)) {
                err_out.err("{s} is already installed as {s}.", .{ name, new_name });
                std.process.exit(1);
            }

            // Perform native rename migration.
            if (dry_run) {
                out.print("Would migrate {s} to {s}\n", .{ name, new_name });
                continue;
            }

            migrateRename(allocator, config, name, new_name, out, err_out);
            continue;
        }

        // 4. Check forward lookup for deprecation replacement.
        if (idx.lookup(name)) |entry| {
            const replacement = idx.getString(entry.replacement_offset);
            if (replacement.len > 0) {
                out.print("==> {s} is deprecated, replacement is {s}.\n", .{ name, replacement });
                out.print("Falling back to brew migrate...\n", .{});
                fallbackToBrew(allocator, args);
            }

            // Formula exists by current name with no replacement — already migrated or no migration needed.
            out.print("{s} is already using its current name. Nothing to migrate.\n", .{name});
            continue;
        }

        // 5. Not found anywhere.
        err_out.err("No migration available for {s}.", .{name});
        std.process.exit(1);
    }
}

/// Perform a native rename migration: unlink old -> rename cellar dir -> relink new.
fn migrateRename(
    allocator: Allocator,
    config: Config,
    old_name: []const u8,
    new_name: []const u8,
    out: Output,
    err_out: Output,
) void {
    const cellar = Cellar.init(config.cellar);

    // Get installed versions for unlinking.
    const versions = cellar.installedVersions(allocator, old_name) orelse {
        err_out.err("{s} has no installed versions.", .{old_name});
        std.process.exit(1);
    };
    defer {
        for (versions) |v| allocator.free(v);
        allocator.free(versions);
    }

    // Use the latest version.
    const latest = blk: {
        const PkgVersion = @import("../version.zig").PkgVersion;
        var best = versions[0];
        for (versions[1..]) |v| {
            if (PkgVersion.parse(v).order(PkgVersion.parse(best)) == .gt) best = v;
        }
        break :blk best;
    };

    out.print("==> Migrating {s} to {s}\n", .{ old_name, new_name });

    // Step 1: Unlink old name.
    out.print("Unlinking {s}...\n", .{old_name});
    {
        var keg_buf: [fs.max_path_bytes]u8 = undefined;
        const old_keg = std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ config.cellar, old_name, latest }) catch {
            err_out.err("Path too long.", .{});
            std.process.exit(1);
        };
        var linker = Linker.init(allocator, config.prefix);
        linker.unlink(old_keg) catch {
            err_out.err("Failed to unlink {s}.", .{old_name});
            std.process.exit(1);
        };
    }

    // Step 2: Rename cellar directory.
    out.print("Renaming Cellar directory...\n", .{});
    {
        var old_dir_buf: [fs.max_path_bytes]u8 = undefined;
        const old_dir = std.fmt.bufPrint(&old_dir_buf, "{s}/{s}", .{ config.cellar, old_name }) catch {
            err_out.err("Path too long.", .{});
            std.process.exit(1);
        };
        var new_dir_buf: [fs.max_path_bytes]u8 = undefined;
        const new_dir = std.fmt.bufPrint(&new_dir_buf, "{s}/{s}", .{ config.cellar, new_name }) catch {
            err_out.err("Path too long.", .{});
            std.process.exit(1);
        };
        std.fs.renameAbsolute(old_dir, new_dir) catch {
            err_out.err("Failed to rename {s} to {s} in Cellar.", .{ old_name, new_name });
            std.process.exit(1);
        };
    }

    // Step 3: Relink with new name.
    out.print("Linking {s}...\n", .{new_name});
    {
        var keg_buf: [fs.max_path_bytes]u8 = undefined;
        const new_keg = std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ config.cellar, new_name, latest }) catch {
            err_out.err("Path too long.", .{});
            std.process.exit(1);
        };
        var linker = Linker.init(allocator, config.prefix);
        linker.link(new_name, new_keg) catch {
            err_out.err("Failed to link {s}.", .{new_name});
            std.process.exit(1);
        };
    }

    // Step 4: Update pin if pinned.
    if (pin_mod.isPinned(config.prefix, old_name)) {
        out.print("Updating pin...\n", .{});
        var old_pin_buf: [fs.max_path_bytes]u8 = undefined;
        const old_pin = std.fmt.bufPrint(&old_pin_buf, "{s}/var/homebrew/pinned/{s}", .{ config.prefix, old_name }) catch return;
        var new_pin_buf: [fs.max_path_bytes]u8 = undefined;
        const new_pin = std.fmt.bufPrint(&new_pin_buf, "{s}/var/homebrew/pinned/{s}", .{ config.prefix, new_name }) catch return;
        std.fs.renameAbsolute(old_pin, new_pin) catch {};
    }

    out.print("==> Migration complete: {s} -> {s}\n", .{ old_name, new_name });
}

/// Fall back to the real brew binary for migrate.
fn fallbackToBrew(allocator: Allocator, args: []const []const u8) noreturn {
    // Build argv: ["brew", "migrate"] ++ args
    const new_argv = allocator.alloc([]const u8, args.len + 2) catch {
        std.process.exit(1);
    };
    new_argv[0] = "brew";
    new_argv[1] = "migrate";
    if (args.len > 0) {
        @memcpy(new_argv[2..], args);
    }
    fallback.execBrew(allocator, new_argv);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "migrateCmd compiles and has correct signature" {
    const handler: @import("../dispatch.zig").CommandFn = migrateCmd;
    _ = handler;
}
```

**Step 2: Register in dispatch.zig**

Add import at top of `src/dispatch.zig`:

```zig
const migrate = @import("cmd/migrate.zig");
```

Add entry to `native_commands` array:

```zig
    .{ .name = "migrate", .handler = migrate.migrateCmd },
```

**Step 3: Add test reference in main.zig**

Add to the `test` block in `src/main.zig`:

```zig
    _ = @import("cmd/migrate.zig");
```

**Step 4: Run tests**

Run: `zig build test 2>&1 | head -5`
Expected: `Build Summary: 1/1 Test Modules passed.`

**Step 5: Commit**

```bash
git add src/cmd/migrate.zig src/dispatch.zig src/main.zig
git commit -m "feat(migrate): implement native migrate command"
```

---

### Task 5: Add help text for migrate

**Files:**
- Modify: `src/help.zig`

**Step 1: Add migrate to general help**

In `printGeneralHelp`, add `migrate` to the "Package management commands" section, after the `tap` line:

```
        \\  migrate    Migrate renamed or deprecated formulae
```

**Step 2: Add command-specific help**

In `getCommandHelp`, add a new entry to the `entries` tuple:

```zig
        .{ "migrate",
            \\Usage: bru migrate [options] <installed_formula> [...]
            \\
            \\Migrate renamed or deprecated formulae to their replacements.
            \\Handles formula renames natively; falls back to brew for
            \\deprecation replacements and tap migrations.
            \\
            \\Options:
            \\  --force, -f    Treat installed and provided formula as if from same taps
            \\  --dry-run, -n  Show what would be migrated without making changes
            \\  --formula      Only migrate formulae
            \\  --cask         Only migrate casks
            \\
        },
```

**Step 3: Update help test**

Add `"migrate"` to the `getCommandHelp returns help for known commands` test:

```zig
    try std.testing.expect(getCommandHelp("migrate") != null);
```

**Step 4: Run tests**

Run: `zig build test 2>&1 | head -5`
Expected: `Build Summary: 1/1 Test Modules passed.`

**Step 5: Commit**

```bash
git add src/help.zig
git commit -m "feat(migrate): add help text for migrate command"
```

---

### Task 6: Final integration verification

**Step 1: Run full test suite**

Run: `zig build test 2>&1 | head -5`
Expected: `Build Summary: 1/1 Test Modules passed.`

**Step 2: Build release binary and smoke test**

Run: `zig build`

Then test:
- `./zig-out/bin/bru migrate --help` — should show help text
- `./zig-out/bin/bru migrate` — should show "requires at least one" error
- `./zig-out/bin/bru migrate nonexistent_formula_xyz` — should show "not installed" error

**Step 3: Commit any fixes and final squash**

If all looks good, no further commits needed.
