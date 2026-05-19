# shellcheck shell=bash
# _bench_common.sh — sourced by bench_contenders.sh and bench_chart.sh.
# Provides path resolution, per-tool detection, and small logging helpers.
# Do not execute directly. No shebang on purpose.

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$COMMON_DIR/../.." && pwd)"
BRU="$PROJECT_ROOT/zig-out/bin/bru"

HOMEBREW_CACHE=""
HOMEBREW_CELLAR=""
if command -v brew >/dev/null 2>&1; then
    HOMEBREW_CACHE="$(brew --cache 2>/dev/null || true)"
    HOMEBREW_CELLAR="$(brew --cellar 2>/dev/null || true)"
fi

die()  { echo "Error: $*" >&2; exit 1; }
log()  { printf '%s\n' "$*"; }
step() { printf '  %s\n' "$*"; }

# Tools in chart/render order (top → bottom).
TOOL_ORDER=(brew zb nb mt bru)

# Pretty-print a version row. Prepends "v" only when $1 starts with a digit
# so "not installed" and "—" placeholders aren't decorated.
print_version_row() {
    local name="$1" ver="$2"
    case "$ver" in
        [0-9]*) printf '  %-6s v%s\n' "$name" "$ver" ;;
        *)      printf '  %-6s %s\n'  "$name" "$ver" ;;
    esac
}

# ── brew ──────────────────────────────────────────────────────────────
brew_present() { command -v brew >/dev/null 2>&1; }
brew_version() { brew --version 2>/dev/null | awk 'NR==1 {print $2}'; }

# ── bru ───────────────────────────────────────────────────────────────
# The benchmark measures the local build at $BRU so changes in this worktree
# are reflected. If that binary hasn't been built yet, fall back to whatever
# `bru` is on PATH so version probes still resolve.
bru_resolved_bin() {
    if [ -x "$BRU" ]; then
        echo "$BRU"
    else
        command -v bru 2>/dev/null
    fi
}
bru_present() {
    local b; b=$(bru_resolved_bin)
    [ -n "$b" ] && [ -x "$b" ]
}
bru_version() {
    local b; b=$(bru_resolved_bin)
    [ -z "$b" ] && return 0
    "$b" --version 2>/dev/null | awk 'NR==1 {print $2}'
}

# ── nb (nanobrew) ─────────────────────────────────────────────────────
NB_BIN="${NB_BIN:-}"
nb_present() {
    if [ -z "$NB_BIN" ]; then
        NB_BIN="$(command -v nb 2>/dev/null || true)"
        [ -z "$NB_BIN" ] && [ -x /opt/nanobrew/prefix/bin/nb ] && NB_BIN=/opt/nanobrew/prefix/bin/nb
    fi
    [ -n "$NB_BIN" ] && [ -x "$NB_BIN" ]
}
nb_version() {
    # nanobrew with no args prints a banner like "nanobrew v0.1.193 — ...".
    # The exit code is nonzero (no command given) so capture the output via
    # `|| true` rather than running the pipeline directly.
    local raw
    raw=$("$NB_BIN" 2>&1 || true)
    printf '%s' "$raw" | sed -nE '1s/.*v([0-9][0-9.]*).*/\1/p'
}

# ── zb (zerobrew) ─────────────────────────────────────────────────────
ZB_BIN="${ZB_BIN:-}"
zb_present() {
    if [ -z "$ZB_BIN" ]; then
        ZB_BIN="$(command -v zb 2>/dev/null || true)"
        [ -z "$ZB_BIN" ] && [ -x /opt/zerobrew/bin/zb ] && ZB_BIN=/opt/zerobrew/bin/zb
        [ -z "$ZB_BIN" ] && [ -x "$HOME/.local/bin/zb" ] && ZB_BIN="$HOME/.local/bin/zb"
    fi
    [ -n "$ZB_BIN" ] && [ -x "$ZB_BIN" ]
}
zb_version() {
    "$ZB_BIN" --version 2>/dev/null | awk 'NR==1 {print $NF}'
}

# ── mt (malt) ─────────────────────────────────────────────────────────
MT_BIN="${MT_BIN:-}"
mt_present() {
    if [ -z "$MT_BIN" ]; then
        MT_BIN="$(command -v malt 2>/dev/null || command -v mt 2>/dev/null || true)"
        [ -z "$MT_BIN" ] && [ -x /usr/local/bin/malt ] && MT_BIN=/usr/local/bin/malt
    fi
    [ -n "$MT_BIN" ] && [ -x "$MT_BIN" ]
}
mt_version() {
    "$MT_BIN" --version 2>/dev/null | awk 'NR==1 {print $NF}'
}
