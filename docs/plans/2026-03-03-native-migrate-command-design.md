# Native `migrate` Command Design

**Issue:** #61
**Date:** 2026-03-03
**Branch:** feat/native-command-migrate

## Overview

Implement `bru migrate <formula>` as a native command. Migrates renamed or deprecated formulas to their replacements, handling three scenarios: simple renames, deprecation replacements, and tap migrations.

## Migration Scenarios

### 1. Simple Rename (handled natively)

Formula was renamed within the same tap. The new formula's JSON has the old name in `oldnames`.

Example: `gnome-icon-theme` → `adwaita-icon-theme`

**Flow:** unlink old → rename Cellar directory → relink with new name → update opt link → update pin if pinned

### 2. Deprecation Replacement (fallback to brew)

A deprecated formula specifies a completely different formula as its replacement via `deprecation_replacement_formula`.

Example: `aftman` → `mise`

**Flow:** Fall back to `brew migrate` since this is essentially uninstall+install of a different formula requiring dependency resolution.

### 3. Tap Migration (fallback to brew)

Formula moved between taps or converted from formula to cask. Tracked in `formula_tap_migrations.jws.json`.

Example: `minetest` → `homebrew/cask/luanti`

**Flow:** Fall back to `brew migrate` since this may involve cask installation.

## Data Model Changes

### FormulaInfo (formula.zig)

Add two fields:

```zig
oldnames: []const []const u8,       // Previous names (e.g., ["gnome-icon-theme"])
deprecation_replacement: []const u8, // Replacement formula name (empty if none)
```

### IndexEntry (index.zig)

Add two offset fields:

```zig
oldnames_offset: u32,      // String list in string table (same format as deps)
replacement_offset: u32,   // Null-terminated string offset
```

### Secondary Hash Table

A second hash table in the index maps oldname → entry_index. This enables O(1) reverse lookup (given an old name, find the current formula entry).

Layout in the binary index:
- Existing hash table: name → entry_index
- New hash table: oldname → entry_index (appended after string table)
- New header field: `oldname_hash_table_offset: u64`

### Index Version Bump

Version 2 → 3. Stale v2 indexes are automatically rejected and rebuilt.

## Tap Migrations

### Source File

`{cache}/api/formula_tap_migrations.jws.json` — JWS envelope containing a JSON object mapping old names to new tap locations.

### Data Format

```json
{
  "android-ndk": "homebrew/cask",
  "minetest": "homebrew/cask/luanti"
}
```

Values:
- `"homebrew/cask"` — moved to cask with same name
- `"homebrew/cask/name"` — moved to cask with different name
- `"tap/name"` — moved to different formula tap

### Implementation

New `src/tap_migrations.zig` module:
- `TapMigrations.load(allocator, cache_dir) -> ?TapMigrations`
- `lookup(old_name) -> ?[]const u8` — returns the target string

## Command Implementation

### File: `src/cmd/migrate.zig`

### Usage

```
bru migrate [--force] [--dry-run/-n] [--formula] [--cask] <formula> [...]
```

### Flags

| Flag | Short | Description |
|------|-------|-------------|
| `--force` | `-f` | Treat installed and provided formula as if from same taps |
| `--dry-run` | `-n` | Show what would be migrated without acting |
| `--formula` | | Only migrate formulae |
| `--cask` | | Only migrate casks |

### Algorithm

For each provided formula name:

1. **Check installed** — verify name exists in Cellar. Error if not.
2. **Check tap migrations** — look up name in tap migrations file:
   - If found → fall back to `brew migrate` (may involve cask install or cross-tap operations)
3. **Check index reverse lookup** — look up name in oldnames hash table:
   - If found → this is a **simple rename**. The entry's `name` field is the new name.
   - Perform native migration (see below).
4. **Check forward lookup + deprecation replacement** — look up name in main hash table:
   - If entry exists and has `deprecation_replacement` → fall back to `brew migrate` (different formula, needs dep resolution)
5. **No migration found** — check if already under current name (no-op) or error.

### Native Migration (Simple Rename)

```
==> Migrating {old_name} to {new_name}
Unlinking {old_name}...
  → linker.unlink(old_keg_path)
Renaming Cellar directory...
  → fs.rename({cellar}/{old}, {cellar}/{new})
Linking {new_name}...
  → linker.link(new_name, new_keg_path)
```

Also:
- Update pin symlink if formula was pinned (rename `{prefix}/var/homebrew/pinned/{old}` → `{new}`)
- With `--dry-run`: print actions without executing

### Fallback

For scenarios 2 and 3, construct argv as `["brew", "migrate", ...original_args]` and call `fallback.execBrew()`.

## Files Changed

| File | Change |
|------|--------|
| `src/formula.zig` | Add `oldnames`, `deprecation_replacement` fields; parse from JSON; free in `freeFormula` |
| `src/index.zig` | Add fields to `IndexEntry`; build secondary oldnames hash table; add `lookupByOldname()` method; bump version to 3; add `oldname_hash_table_offset` to header |
| `src/tap_migrations.zig` | **New** — parse tap migrations JWS, expose lookup |
| `src/cmd/migrate.zig` | **New** — migrate command handler |
| `src/dispatch.zig` | Import migrate module; add entry to `native_commands` |
| `src/main.zig` | Add `_ = @import("cmd/migrate.zig")` and `_ = @import("tap_migrations.zig")` to test block |
| `src/help.zig` | Add migrate help text and entry in general help |

## Testing Strategy

- **Unit tests in migrate.zig:** Signature test, argument parsing
- **Unit tests in index.zig:** Build index with oldnames, verify `lookupByOldname()`
- **Unit tests in tap_migrations.zig:** Parse sample JSON, lookup behavior
- **Unit tests in formula.zig:** Parse formula JSON with oldnames and replacement fields
- **Integration:** Manual testing with real Homebrew data
