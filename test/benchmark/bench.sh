#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BRU="$PROJECT_ROOT/zig-out/bin/bru"
RUNS=5
DIFF_DIR=$(mktemp -d)
trap 'rm -rf "$DIFF_DIR"' EXIT

# ── Helpers ──────────────────────────────────────────────────────────

# Time a command in milliseconds (average over $RUNS runs, with 1 warm-up).
# Uses bash's built-in `time` keyword for accurate wall-clock measurement.
time_cmd() {
    local bin="$1"
    shift

    # Warm-up run (discard)
    $bin "$@" >/dev/null 2>&1 || true

    local total_ms=0
    for _ in $(seq 1 $RUNS); do
        local secs
        secs=$( { TIMEFORMAT='%R'; time $bin "$@" >/dev/null 2>&1; } 2>&1 )
        local ms
        ms=$(awk "BEGIN {printf \"%d\", $secs * 1000}")
        total_ms=$((total_ms + ms))
    done
    echo $((total_ms / RUNS))
}

# Compare outputs. Returns: "pass", "fail", or "loose" (expected differences).
# Usage: compare_output <mode> <args...>
#   mode: exact | sorted | loose
compare_output() {
    local mode="$1"
    shift

    local bru_out brew_out
    bru_out=$("$BRU" "$@" 2>/dev/null) || true
    brew_out=$(brew "$@" 2>/dev/null) || true

    case "$mode" in
        exact)
            if [ "$bru_out" = "$brew_out" ]; then
                echo "pass"
            else
                echo "fail"
            fi
            ;;
        sorted)
            local bru_sorted brew_sorted
            bru_sorted=$(echo "$bru_out" | sort)
            brew_sorted=$(echo "$brew_out" | sort)
            if [ "$bru_sorted" = "$brew_sorted" ]; then
                echo "pass"
            else
                echo "fail"
            fi
            ;;
        loose)
            # Both produce output — differences are expected (e.g. formatting)
            if [ "$bru_out" = "$brew_out" ]; then
                echo "pass"
            else
                echo "loose"
            fi
            ;;
    esac
}

# Save diff to file for later display
save_diff() {
    local desc="$1" mode="$2"
    shift 2

    local bru_out brew_out
    bru_out=$("$BRU" "$@" 2>/dev/null) || true
    brew_out=$(brew "$@" 2>/dev/null) || true

    local bru_cmp brew_cmp
    if [ "$mode" = "sorted" ]; then
        bru_cmp=$(echo "$bru_out" | sort)
        brew_cmp=$(echo "$brew_out" | sort)
    else
        bru_cmp="$bru_out"
        brew_cmp="$brew_out"
    fi

    local safe_name
    safe_name=$(echo "$desc" | tr ' ' '_')
    diff <(echo "$brew_cmp") <(echo "$bru_cmp") > "$DIFF_DIR/$safe_name.diff" 2>&1 || true
}

# Print a formatted table row
row() {
    printf "│ %-22s │ %10s │ %10s │ %10s │ %8s │\n" "$1" "$2" "$3" "$4" "$5"
}

separator() {
    printf "├────────────────────────┼────────────┼────────────┼────────────┼──────────┤\n"
}

# ── Build ────────────────────────────────────────────────────────────

echo "Building bru (ReleaseFast)..."
cd "$PROJECT_ROOT"
zig build -Doptimize=ReleaseFast
echo ""

# Verify both binaries exist
if ! command -v brew &>/dev/null; then
    echo "Error: brew not found in PATH"
    exit 1
fi
if [ ! -x "$BRU" ]; then
    echo "Error: bru not found at $BRU"
    exit 1
fi

# ── Define benchmarks ────────────────────────────────────────────────

# Each benchmark: "description|compare_mode|arg1 arg2 ..."
BENCHMARKS=(
    "--prefix|exact|--prefix"
    "--cellar|exact|--cellar"
    "--cache|exact|--cache"
    "list|sorted|list"
    "list --versions|sorted|list --versions"
    "leaves|sorted|leaves"
    "outdated|exact|outdated"
    "search bat|sorted|search bat"
    "deps bat|exact|deps bat"
    "info bat|loose|info bat"
)

# ── Run benchmarks ───────────────────────────────────────────────────

echo "Benchmarking bru vs brew ($RUNS runs each, 1 warm-up)..."
echo ""

declare -a DESCS BREW_TIMES BRU_TIMES MATCHES
MISMATCHES=0

for bench in "${BENCHMARKS[@]}"; do
    IFS='|' read -r desc mode args <<< "$bench"
    echo -n "  $desc ..."

    # Correctness check first
    # shellcheck disable=SC2086
    match=$(compare_output "$mode" $args)
    if [ "$match" = "fail" ]; then
        # shellcheck disable=SC2086
        save_diff "$desc" "$mode" $args
        MISMATCHES=$((MISMATCHES + 1))
    fi

    # Timing
    # shellcheck disable=SC2086
    brew_ms=$(time_cmd brew $args)
    # shellcheck disable=SC2086
    bru_ms=$(time_cmd "$BRU" $args)

    DESCS+=("$desc")
    BREW_TIMES+=("$brew_ms")
    BRU_TIMES+=("$bru_ms")
    MATCHES+=("$match")

    echo " done (brew=${brew_ms}ms, bru=${bru_ms}ms, ${match})"
done

# ── Print results table ──────────────────────────────────────────────

echo ""
echo "┌────────────────────────┬────────────┬────────────┬────────────┬──────────┐"
row "Command" "brew" "bru" "Speedup" "Match"
echo "├────────────────────────┼────────────┼────────────┼────────────┼──────────┤"

total_brew=0
total_bru=0

for i in "${!DESCS[@]}"; do
    brew_ms="${BREW_TIMES[$i]}"
    bru_ms="${BRU_TIMES[$i]}"
    match="${MATCHES[$i]}"
    total_brew=$((total_brew + brew_ms))
    total_bru=$((total_bru + bru_ms))

    if [ "$bru_ms" -gt 0 ]; then
        speedup=$(awk "BEGIN {printf \"%.1fx\", $brew_ms / $bru_ms}")
    else
        speedup="inf"
    fi

    match_icon=""
    case "$match" in
        pass)  match_icon="PASS" ;;
        loose) match_icon="~" ;;
        fail)  match_icon="FAIL" ;;
    esac

    row "${DESCS[$i]}" "${brew_ms}ms" "${bru_ms}ms" "$speedup" "$match_icon"
done

separator

if [ "$total_bru" -gt 0 ]; then
    total_speedup=$(awk "BEGIN {printf \"%.1fx\", $total_brew / $total_bru}")
else
    total_speedup="inf"
fi

row "TOTAL" "${total_brew}ms" "${total_bru}ms" "$total_speedup" ""
echo "└────────────────────────┴────────────┴────────────┴────────────┴──────────┘"
echo ""
echo "Runs per command: $RUNS (+ 1 warm-up)"
echo "Match: PASS = identical output, ~ = expected formatting differences, FAIL = output mismatch"

# ── Show diffs for failures ──────────────────────────────────────────

if [ "$MISMATCHES" -gt 0 ]; then
    echo ""
    echo "=== Output diffs ($MISMATCHES mismatches) ==="
    echo "(see test/compat/compare.sh for full compatibility testing)"
    for f in "$DIFF_DIR"/*.diff; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .diff | tr '_' ' ')
        echo ""
        echo "--- $name (brew < | bru >) ---"
        head -20 "$f"
    done
fi
