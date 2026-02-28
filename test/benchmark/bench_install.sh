#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BRU="$PROJECT_ROOT/zig-out/bin/bru"

# Configurable package list
DEFAULT_PACKAGES="ffmpeg libsodium duckdb tesseract"
PACKAGES="${PACKAGES:-$DEFAULT_PACKAGES}"

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
fi

HOMEBREW_CACHE="${HOMEBREW_CACHE:-$(brew --cache)}"
HOMEBREW_CELLAR="${HOMEBREW_CELLAR:-$(brew --cellar)}"

# ── Helpers ──────────────────────────────────────────────────────────

die() {
    echo "Error: $*" >&2
    exit 1
}

# Time a single install in milliseconds.
# Usage: time_install <bin> <formula>
time_install() {
    local bin="$1" formula="$2"
    local secs
    secs=$( { TIMEFORMAT='%R'; time $bin install "$formula" >/dev/null 2>&1; } 2>&1 )
    awk "BEGIN {printf \"%d\", $secs * 1000}"
}

# Uninstall a formula (ignoring dependencies).
uninstall_formula() {
    local formula="$1"
    if brew list --formula "$formula" &>/dev/null; then
        brew uninstall --ignore-dependencies "$formula" &>/dev/null || true
    fi
}

# Remove cached downloads matching formula name.
# brew caches as: {sha256}--{name}--{version}.{arch}.bottle.tar.gz
# bru  caches as: {sha256}--{name}
# The pattern *--{name}* covers both.
clear_cache() {
    local formula="$1"
    find "$HOMEBREW_CACHE/downloads" -name "*--${formula}*" -delete 2>/dev/null || true
}

# Pre-install all dependencies of a formula so we only benchmark the target.
ensure_deps_installed() {
    local formula="$1"
    local deps
    deps=$(brew deps "$formula" 2>/dev/null) || return 0
    if [ -n "$deps" ]; then
        echo "    pre-installing deps: $deps"
        if $DRY_RUN; then return 0; fi
        # Install missing deps only
        for dep in $deps; do
            if ! brew list --formula "$dep" &>/dev/null; then
                brew install "$dep" >/dev/null 2>&1
            fi
        done
    fi
}

# Print a formatted table row
row() {
    printf "│ %-14s │ %12s │ %12s │ %12s │ %12s │ %12s │ %12s │\n" "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

separator() {
    printf "├────────────────┼──────────────┼──────────────┼──────────────┼──────────────┼──────────────┼──────────────┤\n"
}

# ── Safety checks ────────────────────────────────────────────────────

if ! command -v brew &>/dev/null; then
    die "brew not found in PATH"
fi

if [ ! -d "$HOMEBREW_CACHE" ]; then
    die "Homebrew cache not found at $HOMEBREW_CACHE"
fi

if [ ! -d "$HOMEBREW_CELLAR" ]; then
    die "Homebrew cellar not found at $HOMEBREW_CELLAR"
fi

# ── Build ────────────────────────────────────────────────────────────

echo "Building bru (ReleaseFast)..."
if $DRY_RUN; then
    echo "  [dry-run] would run: zig build -Doptimize=ReleaseFast"
else
    cd "$PROJECT_ROOT"
    zig build -Doptimize=ReleaseFast
fi

if ! $DRY_RUN && [ ! -x "$BRU" ]; then
    die "bru not found at $BRU"
fi

# ── Run benchmarks ──────────────────────────────────────────────────

echo ""
echo "Benchmarking install: bru vs brew"
echo "Packages: $PACKAGES"
echo ""

declare -a PKG_NAMES BREW_COLD_TIMES BREW_WARM_TIMES BRU_COLD_TIMES BRU_WARM_TIMES

for formula in $PACKAGES; do
    echo "[$formula]"

    # 0. Pre-install dependencies
    ensure_deps_installed "$formula"

    if $DRY_RUN; then
        echo "    [dry-run] brew cold: uninstall + clear cache + brew install $formula"
        echo "    [dry-run] brew warm: uninstall + keep cache  + brew install $formula"
        echo "    [dry-run] bru cold:  uninstall + clear cache + bru install $formula"
        echo "    [dry-run] bru warm:  uninstall + keep cache  + bru install $formula"
        echo "    [dry-run] cleanup:   uninstall $formula"
        PKG_NAMES+=("$formula")
        BREW_COLD_TIMES+=(0)
        BREW_WARM_TIMES+=(0)
        BRU_COLD_TIMES+=(0)
        BRU_WARM_TIMES+=(0)
        echo ""
        continue
    fi

    # 1. brew cold: no cached bottle
    echo -n "    brew cold ..."
    uninstall_formula "$formula"
    clear_cache "$formula"
    brew_cold=$(time_install brew "$formula")
    echo " ${brew_cold}ms"

    # 2. brew warm: bottle in cache
    echo -n "    brew warm ..."
    uninstall_formula "$formula"
    brew_warm=$(time_install brew "$formula")
    echo " ${brew_warm}ms"

    # 3. bru cold: no cached bottle
    echo -n "    bru cold  ..."
    uninstall_formula "$formula"
    clear_cache "$formula"
    bru_cold=$(time_install "$BRU" "$formula")
    echo " ${bru_cold}ms"

    # 4. bru warm: bottle in cache
    echo -n "    bru warm  ..."
    uninstall_formula "$formula"
    bru_warm=$(time_install "$BRU" "$formula")
    echo " ${bru_warm}ms"

    # 5. Cleanup
    uninstall_formula "$formula"

    PKG_NAMES+=("$formula")
    BREW_COLD_TIMES+=("$brew_cold")
    BREW_WARM_TIMES+=("$brew_warm")
    BRU_COLD_TIMES+=("$bru_cold")
    BRU_WARM_TIMES+=("$bru_warm")

    echo ""
done

# ── Print results table ─────────────────────────────────────────────

echo "┌────────────────┬──────────────┬──────────────┬──────────────┬──────────────┬──────────────┬──────────────┐"
row "Package" "brew cold" "brew warm" "bru cold" "bru warm" "Cold Speedup" "Warm Speedup"
echo "├────────────────┼──────────────┼──────────────┼──────────────┼──────────────┼──────────────┼──────────────┤"

total_brew_cold=0
total_brew_warm=0
total_bru_cold=0
total_bru_warm=0

for i in "${!PKG_NAMES[@]}"; do
    bc="${BREW_COLD_TIMES[$i]}"
    bw="${BREW_WARM_TIMES[$i]}"
    rc="${BRU_COLD_TIMES[$i]}"
    rw="${BRU_WARM_TIMES[$i]}"

    total_brew_cold=$((total_brew_cold + bc))
    total_brew_warm=$((total_brew_warm + bw))
    total_bru_cold=$((total_bru_cold + rc))
    total_bru_warm=$((total_bru_warm + rw))

    if [ "$rc" -gt 0 ]; then
        cold_speedup=$(awk "BEGIN {printf \"%.1fx\", $bc / $rc}")
    else
        cold_speedup="inf"
    fi

    if [ "$rw" -gt 0 ]; then
        warm_speedup=$(awk "BEGIN {printf \"%.1fx\", $bw / $rw}")
    else
        warm_speedup="inf"
    fi

    row "${PKG_NAMES[$i]}" "${bc}ms" "${bw}ms" "${rc}ms" "${rw}ms" "$cold_speedup" "$warm_speedup"
done

separator

if [ "$total_bru_cold" -gt 0 ]; then
    total_cold_speedup=$(awk "BEGIN {printf \"%.1fx\", $total_brew_cold / $total_bru_cold}")
else
    total_cold_speedup="inf"
fi

if [ "$total_bru_warm" -gt 0 ]; then
    total_warm_speedup=$(awk "BEGIN {printf \"%.1fx\", $total_brew_warm / $total_bru_warm}")
else
    total_warm_speedup="inf"
fi

row "TOTAL" "${total_brew_cold}ms" "${total_brew_warm}ms" "${total_bru_cold}ms" "${total_bru_warm}ms" "$total_cold_speedup" "$total_warm_speedup"
echo "└────────────────┴──────────────┴──────────────┴──────────────┴──────────────┴──────────────┴──────────────┘"
echo ""
echo "Cold = no cached bottle (download + extract + link)"
echo "Warm = bottle in cache (extract + link only)"
