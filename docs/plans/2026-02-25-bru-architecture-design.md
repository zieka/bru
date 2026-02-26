# bru Architecture Design

A drop-in replacement for Homebrew's `brew` CLI, written in Zig for speed. Complete feature parity with brew, resolving orders of magnitude faster.

## Strategy: Progressive Replacement

bru starts by natively implementing the highest-impact commands and transparently delegates unimplemented commands to the real `brew` binary via exec. Over time, each command graduates from delegation to native Zig. Users always get a working result — native commands are fast, delegated commands behave identically to brew.

## Core Decisions

- **Fully filesystem compatible** — Same Cellar, Caskroom, cache, API files, Tab format. `bru` and `brew` are interchangeable on the same system.
- **Exec fallback** — Unimplemented commands exec `brew` with the original argv. Brew binary found via `HOMEBREW_BREW_FILE`, `which brew`, or known paths.
- **Single static binary** — Zero runtime dependencies. Zig's self-contained compilation. Trivial install: download, put in PATH.
- **Pre-indexed binary format** — Converts Homebrew's ~25MB of JSON API data into mmap'd binary index files for O(1) lookups.

## Command Tiers

### Tier 1 — Read-only, pure speed wins (implement first)
- `list` / `ls` — scan Cellar
- `info` — index lookup
- `search` — substring/regex over index
- `outdated` — compare installed vs index
- `deps` / `uses` — dependency graph traversal
- `leaves` — set difference on graph
- `--prefix`, `--cellar`, `--cache`, `--version` — instant returns
- `config` — system info

### Tier 2 — Write operations, high value
- `install` (bottle path) — download, extract, link
- `uninstall` — remove keg, unlink
- `upgrade` — outdated + install
- `link` / `unlink` — symlink management
- `cleanup` / `autoremove` — scan + delete
- `update` — fetch API JSON, rebuild index
- `fetch` — download without installing

### Tier 3 — Complex / lower frequency
- `bundle` — Brewfile parsing + orchestration
- `services` — launchctl/systemd integration
- `tap` / `untap` — git clone management
- `doctor` — diagnostic checks
- `pin` / `unpin`, `migrate`, `shellenv`, `completions`

### Tier 4 — Delegate to brew indefinitely
- All dev-cmd commands (`audit`, `bottle`, `bump-*`, `create`, `test-bot`, etc.)

## Binary Structure & Command Dispatch

Single Zig binary with a comptime-built dispatch table mapping command names (including aliases) to handler functions. Every handler has the same signature: `fn(allocator, args, config) !void`.

Startup path: parse argv → load config from env → dispatch → run.

No index loading until a command actually needs formula data.

### Config Loading
Reads environment variables with the same defaults and precedence as brew. Also reads `brew.env` files from `/etc/homebrew/brew.env` and `~/.homebrew/brew.env`. Simple key-value parser.

### Aliases
Same as brew: `ls` → `list`, `rm` → `uninstall`, `dr` → `doctor`, `-S` → `search`, etc.

### Global Flags
`--debug`, `--verbose`, `--quiet`, `--help` handled before dispatch.

## Binary Index Format

Converts `formula.jws.json` and `cask.jws.json` into memory-mappable files stored alongside the JSON in `~/Library/Caches/Homebrew/api/`.

### Layout

```
Header (64 bytes):
  magic: "BRUI" (4 bytes)
  version: u32
  source_hash: [32]u8    (SHA-256 of source JSON for staleness)
  entry_count: u32
  hash_table_offset: u64
  entries_offset: u64
  strings_offset: u64

Hash Table (open addressing, entry_count * 2 buckets):
  Each bucket: { string_offset: u32, entry_offset: u32 }

Entries (fixed-size records per formula):
  name_offset: u32
  full_name_offset: u32
  desc_offset: u32
  version_offset: u32
  revision: u16
  bottle_available: bool
  deprecated: bool
  disabled: bool
  keg_only: bool
  deps_offset: u32
  tap_offset: u32
  homepage_offset: u32
  license_offset: u32
  ... (remaining fields)

String Table:
  Null-terminated UTF-8 strings, packed sequentially

Variable-length data:
  Dependency lists, bottle tags as length-prefixed arrays
```

### Operations
- **Lookup**: hash name → probe table → follow entry offset → read record.
- **Search**: scan entries, match name against pattern.
- **Staleness**: compare header SHA-256 against JSON file hash. Auto-rebuild if mismatched.

Installed state is read from the Cellar at query time, not stored in the index.

## Core Modules

### `config.zig`
Loads environment variables and `brew.env` files. Resolves all paths. Detects platform. Produces immutable config struct shared by all commands.

### `index.zig`
Binary index management. `open()` (mmap), `lookup(name)`, `search(pattern)`, `iter()`. Staleness detection and rebuild trigger.

### `cellar.zig`
Reads installed state from filesystem. Scans `HOMEBREW_CELLAR/`, parses `INSTALL_RECEIPT.json` Tab files. Provides `installed_formulae()`, `is_installed(name)`, `installed_versions(name)`.

### `caskroom.zig`
Same pattern for casks via `HOMEBREW_CASKROOM/`.

### `linker.zig`
Symlink management between kegs and `HOMEBREW_PREFIX/{bin,lib,include,share,...}`. Mirrors brew's linking strategy exactly:
- `bin`/`sbin`: flat (symlink files, skip directories)
- `etc`: real directories, symlink files
- `lib`: default link, `mkpath` for `pkgconfig`, `cmake`, `python3.x`, etc.
- `share`: default link, `mkpath` for `locale`, `man`, `icons`, `zsh`, `fish`, etc.
- `opt` links: `HOMEBREW_PREFIX/opt/<name>` → keg

### `fetch.zig`
HTTP client using `std.http.Client`. GitHub Packages OCI manifest resolution for bottle URLs. Resume, retry, checksum verification. Writes to `HOMEBREW_CACHE/downloads/`.

### `bottle.zig`
Gzip decompression and tar extraction via `std.compress` and `std.tar`. Path placeholder replacement (`@@HOMEBREW_PREFIX@@` → actual prefix). Extracts into Cellar.

### `resolver.zig`
Dependency resolution via recursive DFS on the binary index with cycle detection (bitset). Filters by dep type based on context (skip `:build`/`:test` for bottle installs). Returns topological order. Handles `uses_from_macos` with macOS version bounds checking.

### `jws.zig`
JWS signature verification using PS512 (RSA-PSS with SHA-512). Public key bundled in binary.

### `output.zig`
Formatting, ANSI colors, JSON emission. Respects `HOMEBREW_NO_COLOR`, `HOMEBREW_NO_EMOJI`, `NO_COLOR`.

### `tab.zig`
Read and write `INSTALL_RECEIPT.json` matching brew's exact schema.

### `version.zig`
Version string parsing and comparison matching brew's `PkgVersion` semantics.

## Bottle Installation Pipeline

1. **Resolve** — Index lookup, check if installed, resolve dependency tree, filter already-installed.
2. **Select bottle** — Match platform tag (e.g., `arm64_sequoia`), fall back to compatible older tags. No bottle → exec `brew install`.
3. **Download** — Fetch OCI manifest from ghcr.io, download blob. Cache in `HOMEBREW_CACHE/downloads/` using brew's naming scheme. Skip if cached and checksum matches.
4. **Extract** — Decompress + untar into `HOMEBREW_CELLAR/<name>/<version>/`. Replace path placeholders.
5. **Write Tab** — `INSTALL_RECEIPT.json` with brew-compatible schema.
6. **Link** — Symlink keg contents into prefix. Create opt link.
7. **Post-install** — If formula has `post_install`, exec `brew postinstall <name>`.

## Output Compatibility

### Strict (byte-for-byte)
- `--json=v1` and `--json=v2`: identical schemas, field names, types
- Exit codes match brew's behavior
- `--quiet` output: one name per line

### Visual (match format)
- Green `==> ` section headers, red errors, yellow warnings
- `brew info` field order and layout
- Respect all color/emoji environment variables

### Allowed differences
- Download progress bars (bru can show better progress)
- bru-specific error messages (e.g., "index rebuild needed")
- Optional `--timing` flag

### Testing
Capture `brew <command>` output as reference fixtures. Verify `bru <command>` produces identical results. This is the regression test suite.

## Update & Index Lifecycle

### `bru update`
1. Fetch `formula.jws.json` and `cask.jws.json` from API. Verify JWS signatures. Write to `HOMEBREW_CACHE/api/`.
2. Rebuild binary index if JSON changed (SHA-256 comparison). ~200-300ms.
3. Fetch tap migration data.

### Auto-update
- Check mtime of JSON against `HOMEBREW_AUTO_UPDATE_SECS` (default 24h).
- If stale, fork background update while foreground command uses current index.
- Respect `HOMEBREW_NO_AUTO_UPDATE`.

### Coexistence
- `brew update` refreshes JSON → bru detects stale index on next run → auto-rebuilds.
- `bru update` refreshes JSON → brew sees fresh cache on next run.
- Fully transparent in both directions.

## Project Structure

```
bru/
├── build.zig
├── build.zig.zon
├── src/
│   ├── main.zig
│   ├── config.zig
│   ├── dispatch.zig
│   ├── index.zig
│   ├── cellar.zig
│   ├── caskroom.zig
│   ├── linker.zig
│   ├── fetch.zig
│   ├── bottle.zig
│   ├── resolver.zig
│   ├── jws.zig
│   ├── output.zig
│   ├── tab.zig
│   ├── version.zig
│   └── cmd/
│       ├── list.zig
│       ├── info.zig
│       ├── search.zig
│       ├── install.zig
│       ├── uninstall.zig
│       ├── upgrade.zig
│       ├── outdated.zig
│       ├── deps.zig
│       ├── uses.zig
│       ├── leaves.zig
│       ├── update.zig
│       ├── fetch_cmd.zig
│       ├── cleanup.zig
│       ├── autoremove.zig
│       ├── link.zig
│       ├── pin.zig
│       ├── config_cmd.zig
│       ├── doctor.zig
│       └── prefix.zig
├── test/
│   ├── index_test.zig
│   ├── resolver_test.zig
│   ├── version_test.zig
│   ├── linker_test.zig
│   ├── tab_test.zig
│   └── compat/
│       ├── capture.sh
│       └── verify.sh
└── docs/
    └── plans/
```

## Build & Distribution

- `zig build` — debug build
- `zig build -Doptimize=ReleaseFast` — production, single static binary
- `zig build test` — unit tests
- Cross-compile: `-Dtarget=aarch64-macos` / `x86_64-macos` / `x86_64-linux` / `aarch64-linux`
- Distribution: GitHub releases with pre-built binaries, eventually `brew install bru`
