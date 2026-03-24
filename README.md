# bru

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

## Building from source

Requires [Zig](https://ziglang.org/) 0.15+:

```bash
zig build -Doptimize=ReleaseFast
```

Run tests:

```bash
zig build test
```
