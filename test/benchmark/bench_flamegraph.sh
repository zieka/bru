#!/bin/bash
# bench_flamegraph.sh — Build with -Dtrace, run install, produce Chrome Trace JSON.
#
# Usage: bash test/benchmark/bench_flamegraph.sh [options] [formula]
#   formula   Package to profile (default: libsodium)
#   --warm    Skip cache clearing (profile warm install)
#   --open    Auto-open trace in Perfetto (macOS)
#   --dry-run Preview commands without executing
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BRU="$PROJECT_ROOT/zig-out/bin/bru"
TRACE_FILE="$PROJECT_ROOT/bru-trace.json"

DEFAULT_FORMULA="libsodium"
FORMULA=""
WARM=false
OPEN=false
DRY_RUN=false

# ── Parse arguments ──────────────────────────────────────────────────

for arg in "$@"; do
    case "$arg" in
        --warm)    WARM=true ;;
        --open)    OPEN=true ;;
        --dry-run) DRY_RUN=true ;;
        -*)        echo "Unknown option: $arg" >&2; exit 1 ;;
        *)         FORMULA="$arg" ;;
    esac
done

FORMULA="${FORMULA:-$DEFAULT_FORMULA}"

HOMEBREW_CACHE="${HOMEBREW_CACHE:-$(brew --cache 2>/dev/null || echo "$HOME/Library/Caches/Homebrew")}"
HOMEBREW_CELLAR="${HOMEBREW_CELLAR:-$(brew --cellar 2>/dev/null || echo "/opt/homebrew/Cellar")}"

# ── Helpers ──────────────────────────────────────────────────────────

die() {
    echo "Error: $*" >&2
    exit 1
}

uninstall_formula() {
    local formula="$1"
    if brew list --formula "$formula" &>/dev/null; then
        brew uninstall --ignore-dependencies "$formula" &>/dev/null || true
    fi
}

clear_cache() {
    local formula="$1"
    find "$HOMEBREW_CACHE/downloads" -name "*--${formula}*" -delete 2>/dev/null || true
}

ensure_deps_installed() {
    local formula="$1"
    local deps
    deps=$(brew deps "$formula" 2>/dev/null) || return 0
    if [ -n "$deps" ]; then
        echo "  Pre-installing deps: $deps"
        if $DRY_RUN; then return 0; fi
        for dep in $deps; do
            if ! brew list --formula "$dep" &>/dev/null; then
                brew install "$dep" >/dev/null 2>&1
            fi
        done
    fi
}

# ── Safety checks ────────────────────────────────────────────────────

if ! $DRY_RUN && ! command -v brew &>/dev/null; then
    die "brew not found in PATH"
fi

# ── Build ────────────────────────────────────────────────────────────

echo "Building bru with -Dtrace -Doptimize=ReleaseFast..."
if $DRY_RUN; then
    echo "  [dry-run] would run: zig build -Doptimize=ReleaseFast -Dtrace=true"
else
    cd "$PROJECT_ROOT"
    zig build -Doptimize=ReleaseFast -Dtrace=true
fi

if ! $DRY_RUN && [ ! -x "$BRU" ]; then
    die "bru not found at $BRU"
fi

# ── Prepare ──────────────────────────────────────────────────────────

echo ""
echo "Profiling: $FORMULA"

ensure_deps_installed "$FORMULA"

if $DRY_RUN; then
    if ! $WARM; then
        echo "  [dry-run] would clear cache for $FORMULA"
    fi
    echo "  [dry-run] would uninstall $FORMULA"
    echo "  [dry-run] would run: $BRU install $FORMULA"
    echo "  [dry-run] trace file: $TRACE_FILE"
    exit 0
fi

# Uninstall target
uninstall_formula "$FORMULA"

# Clear cache unless --warm
if ! $WARM; then
    echo "  Clearing cache (cold install)..."
    clear_cache "$FORMULA"
else
    echo "  Keeping cache (warm install)..."
fi

# ── Run ──────────────────────────────────────────────────────────────

echo "  Running: $BRU install $FORMULA"
echo ""

# Remove old trace file
rm -f "$TRACE_FILE"

"$BRU" install "$FORMULA"

echo ""

# ── Report ───────────────────────────────────────────────────────────

if [ -f "$TRACE_FILE" ]; then
    echo "Trace file: $TRACE_FILE"
    echo "Open in browser: https://ui.perfetto.dev/"
    echo ""

    if $OPEN; then
        echo "Opening in Perfetto..."
        open "https://ui.perfetto.dev/"
        echo "Drag $TRACE_FILE into the Perfetto UI to view the trace."
    fi
else
    echo "No trace file generated. Ensure bru was built with -Dtrace=true."
fi

# ── Cleanup ──────────────────────────────────────────────────────────

uninstall_formula "$FORMULA"
