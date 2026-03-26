# bru

[https://zieka.github.io/bru](https://zieka.github.io/bru)

Homebrew, reimagined in native code.

A fast, native implementation of common Homebrew commands written in Zig. Drop-in compatible — falls back to `brew` for anything not yet implemented.

## Install

```bash
curl -fsSL https://zieka.github.io/bru/install.sh | bash
```

## Usage

Use `bru` exactly like you'd use `brew`:

```bash
bru install ripgrep
bru search fd
bru upgrade
bru services start postgresql@14
bru bundle dump
bru rollback ripgrep
```

## Commands

39 native commands including `install`, `upgrade`, `search`, `list`, `info`, `deps`, `doctor`, `cleanup`, plus:

- **services** — manage background services (start/stop/restart)
- **bundle** — export and install from Brewfiles
- **rollback** — revert a formula to its previous version
- **self-update** — update bru itself

Anything not implemented natively falls back to the real `brew` binary.

## How bru compares

### vs Homebrew

| | Homebrew | bru |
|---|---|---|
| **Language** | Ruby | Zig (single static binary) |
| **Startup** | ~1.5s interpreter load | Near-zero |
| **Formula lookups** | Parse 25MB JSON | O(1) via mmap'd binary index |
| **Auto-update** | Runs on every `install` | Never — `bru update` is explicit |
| **Rollback** | Not supported | `bru rollback <formula>` with full history |
| **Memory** | Ruby GC pauses | Arena allocator (free is a no-op) |
| **Downloads** | Sequential | Parallel with worker threads |

### vs zerobrew

| | zerobrew | bru |
|---|---|---|
| **Drop-in compatible** | No — separate `/opt/zerobrew` prefix, requires migration | Yes — same prefix, same Cellar, interchangeable with brew |
| **Fallback** | None — switch to brew manually | Transparent — unimplemented commands delegate to brew automatically |
| **Formula index** | Parses JSON API on every lookup | Binary index (BRUI format), mmap'd O(1) lookups |
| **Dependencies** | ~30 Rust crates, SQLite, Tokio | Zero — Zig stdlib only |
| **Binary size** | 7.9 MB | Single static binary, significantly smaller |
| **Migration** | Required (`zb migrate`) | Not needed — works on existing Homebrew installation |

### vs nanobrew

| | nanobrew | bru |
|---|---|---|
| **Drop-in compatible** | No — separate `/opt/nanobrew` prefix | Yes — same prefix, same Cellar |
| **Fallback** | None — unsupported commands fail | Transparent — delegates to brew |
| **Tar extraction** | Shells out to system `tar` | Native Zig tar with parallel buffer pool |
| **Tab files** | Separate state tracking | Writes brew-compatible `INSTALL_RECEIPT.json` — brew sees bru-installed packages as its own |
| **Mach-O patching** | Not fully implemented | Full relocation via `install_name_tool` + `codesign` |
| **Migration** | Required (`nb migrate`) | Not needed |

### The key difference

bru is designed as a **transparent accelerator**, not a parallel ecosystem. Both zerobrew and nanobrew install into separate prefixes, require migration, and leave you switching tools when something isn't supported. bru sits in front of brew — alias `brew=bru` and everything works, faster for native commands and unchanged for the rest. No migration, no duplicate packages, no split brain.

## Building from source

Requires [Zig](https://ziglang.org/) 0.15+:

```bash
zig build -Doptimize=ReleaseFast
```

Run tests:

```bash
zig build test
```
