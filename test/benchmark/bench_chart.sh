#!/bin/bash
# bench_chart.sh — Time a cold-cache and warm-cache install of each formula
# under every installed contender (brew, zb, nb, mt, bru) and render a
# polished SVG per package.
#
# Prerequisite: run bench_contenders.sh first to ensure every tool is on
# PATH at its latest version. This script does NOT install or update anything
# itself — it only reads versions and measures install times.
#
# Usage:
#   bash test/benchmark/bench_chart.sh
#   bash test/benchmark/bench_chart.sh --dry-run
#
# Env:
#   PACKAGES     space-separated formulae (default: "ffmpeg libsodium duckdb tesseract")
#   SVG_OUTPUT   path prefix; .svg suffix is stripped and "-<pkg>.svg" appended
# Note: deliberately NOT using `set -e`. The bench runs many fallible
# operations (uninstall, cache clear, install) and we want a single failure
# to be recorded as a bad measurement rather than abort the whole run.
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/benchmark/_bench_common.sh
. "$SCRIPT_DIR/_bench_common.sh"

DEFAULT_FORMULAE="act ffmpeg libsodium duckdb tesseract"
DEFAULT_CASKS="rectangle"
# PACKAGES kept for backward compatibility — treated as formulae if FORMULAE
# isn't set explicitly.
FORMULAE="${FORMULAE:-${PACKAGES:-$DEFAULT_FORMULAE}}"
CASKS="${CASKS:-$DEFAULT_CASKS}"
SVG_OUTPUT="${SVG_OUTPUT:-$SCRIPT_DIR/results.svg}"

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then DRY_RUN=true; fi

# ── Per-tool install / uninstall / cache-clear ────────────────────────

# brew
brew_install_pkg()   { brew install "$1"; }
brew_uninstall_pkg() {
    if brew list --formula "$1" &>/dev/null; then
        brew uninstall --ignore-dependencies "$1" &>/dev/null || true
    fi
}
brew_clear_cache() {
    [ -n "$HOMEBREW_CACHE" ] || return 0
    find "$HOMEBREW_CACHE/downloads" -name "*--${1}*" -delete 2>/dev/null || true
}

# bru — shares the Cellar with brew, so brew uninstall removes its kegs too.
# Cache layout (separate from brew's, but both live under $HOMEBREW_CACHE):
#   <cache>/<formula>--<version>             — downloaded bottle (bru-named)
#   <cache>/<formula>_bottle_manifest--*     — bottle manifests
#   <cache>/kegs/<sha>/<formula>/<version>/  — pre-extracted keg (clonefile src)
#   <cache>/downloads/<sha>--<formula>--*    — brew-format archives, if brew
#                                              has touched the cache too
bru_install_pkg()   { "$(bru_resolved_bin)" install "$1"; }
bru_uninstall_pkg() {
    if [ -n "$HOMEBREW_CELLAR" ] && brew list --formula "$1" &>/dev/null; then
        brew uninstall --ignore-dependencies "$1" &>/dev/null || true
    fi
}
bru_clear_cache() {
    local formula=$1
    local cache="${HOMEBREW_CACHE:-$HOME/Library/Caches/Homebrew}"
    [ -d "$cache" ] || return 0

    # 1. bru's flat-named archives + manifests at cache root.
    /usr/bin/find "$cache" -maxdepth 1 \
        \( -name "${formula}--*" -o -name "${formula}_bottle_manifest--*" \) \
        -exec /bin/rm -rf {} + 2>/dev/null

    # 2. brew-format archives under downloads/ (in case brew touched this
    #    cache too).
    if [ -d "$cache/downloads" ]; then
        /usr/bin/find "$cache/downloads" -maxdepth 1 -name "*--${formula}*" \
            -delete 2>/dev/null
    fi

    # 3. bru's pre-extracted kegs: any sha-dir under kegs/ that contains a
    #    <formula>/ subdir is for this formula — remove the whole sha-dir.
    if [ -d "$cache/kegs" ]; then
        /usr/bin/find "$cache/kegs" -mindepth 2 -maxdepth 2 -type d -name "$formula" 2>/dev/null \
            | while IFS= read -r kegdir; do
                /bin/rm -rf "$(/usr/bin/dirname "$kegdir")"
            done
    fi
}

# All three native tools (nb, zb, mt) reuse brew's bottle tarballs and key
# them by the bottle's SHA256 in their cache/blobs and store/ directories.
# Surgical cold-cache invalidation = query the brew API for every per-OS
# bottle SHA of a formula, then delete any file/dir under those caches whose
# basename matches one of those SHAs.

# Print every bottle SHA256 brew knows about for the formula (one per line).
bottle_sha256s() {
    local formula=$1
    brew info --json=v2 "$formula" 2>/dev/null | /usr/bin/python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    files = d["formulae"][0]["bottle"]["stable"]["files"]
    for info in files.values():
        sha = info.get("sha256")
        if sha:
            print(sha)
except Exception:
    pass
'
}

# Delete any entry in $dir whose basename equals a known bottle SHA for
# $formula, or starts with that SHA followed by an extension (e.g. .tar.gz).
clear_by_sha() {
    local dir=$1 formula=$2
    [ -d "$dir" ] || return 0
    local sha
    while IFS= read -r sha; do
        [ -n "$sha" ] || continue
        /usr/bin/find "$dir" -maxdepth 1 \
            \( -name "$sha" -o -name "$sha.*" \) \
            -exec /bin/rm -rf {} + 2>/dev/null
    done < <(bottle_sha256s "$formula")
}

# nb (nanobrew) — cache/blobs/<sha>, store/<sha>/
nb_install_pkg()   { "$NB_BIN" install "$1"; }
nb_uninstall_pkg() { "$NB_BIN" remove "$1" >/dev/null 2>&1 || true; }
nb_clear_cache() {
    clear_by_sha /opt/nanobrew/cache/blobs "$1"
    clear_by_sha /opt/nanobrew/store       "$1"
}

# zb (zerobrew) — cache/blobs/<sha>.tar.gz, store/<sha>/
zb_install_pkg()   { "$ZB_BIN" install "$1"; }
zb_uninstall_pkg() { "$ZB_BIN" uninstall "$1" >/dev/null 2>&1 || true; }
zb_clear_cache() {
    clear_by_sha /opt/zerobrew/cache/blobs "$1"
    clear_by_sha /opt/zerobrew/store       "$1"
}

# mt (malt) — cache/downloads/<sha>, store/<sha>/, store-relocated/<sha>/
mt_install_pkg()   { "$MT_BIN" install "$1"; }
mt_uninstall_pkg() { "$MT_BIN" uninstall "$1" >/dev/null 2>&1 || true; }
mt_clear_cache() {
    local prefix="${MALT_PREFIX:-/opt/malt}"
    clear_by_sha "$prefix/cache/downloads" "$1"
    clear_by_sha "$prefix/store"           "$1"
    clear_by_sha "$prefix/store-relocated" "$1"
}

# ── Cask install / uninstall / cache-clear ───────────────────────────
# Casks ship vendor binaries (.app, fonts, CLI archives). Each cask has a
# single SHA256 (not multiple per-OS variants like a bottle), and tools cache
# the downloaded artifact keyed by that SHA. zerobrew has no cask support.

# Print the cask download SHA256 (single value).
cask_sha256() {
    local name=$1
    brew info --cask --json=v2 "$name" 2>/dev/null | /usr/bin/python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    sha = d["casks"][0].get("sha256", "")
    if sha and sha != "no_check":
        print(sha)
except Exception:
    pass
'
}

# Delete entry in $dir whose basename equals the cask SHA, or starts with it
# followed by an extension or "--<name>--<version>" suffix.
clear_cask_by_sha() {
    local dir=$1 cask=$2
    [ -d "$dir" ] || return 0
    local sha; sha=$(cask_sha256 "$cask")
    [ -z "$sha" ] && return 0
    /usr/bin/find "$dir" -maxdepth 1 \
        \( -name "$sha" -o -name "$sha.*" -o -name "$sha--*" \) \
        -exec /bin/rm -rf {} + 2>/dev/null
    # Some tools also store under <sha>--<cask>--<version>.<ext> naming.
    /usr/bin/find "$dir" -maxdepth 1 -name "*--${cask}--*" \
        -exec /bin/rm -rf {} + 2>/dev/null
}

# brew
brew_install_cask()   { brew install --cask "$1"; }
brew_uninstall_cask() {
    if brew list --cask "$1" &>/dev/null; then
        brew uninstall --cask "$1" &>/dev/null || true
    fi
}
brew_clear_cask_cache() {
    [ -n "$HOMEBREW_CACHE" ] || return 0
    clear_cask_by_sha "$HOMEBREW_CACHE/Cask"      "$1"
    clear_cask_by_sha "$HOMEBREW_CACHE/downloads" "$1"
}

# bru — shares /Applications + Caskroom with brew.
bru_install_cask()   { "$(bru_resolved_bin)" install --cask "$1"; }
bru_uninstall_cask() {
    if brew list --cask "$1" &>/dev/null; then
        brew uninstall --cask "$1" &>/dev/null || true
    fi
}
bru_clear_cask_cache() {
    local cache="${HOMEBREW_CACHE:-$HOME/Library/Caches/Homebrew}"
    [ -d "$cache" ] || return 0
    clear_cask_by_sha "$cache"           "$1"
    clear_cask_by_sha "$cache/Cask"      "$1"
    clear_cask_by_sha "$cache/downloads" "$1"
}

# nb (nanobrew) — `install --cask` / `remove --cask`.
nb_install_cask()   { "$NB_BIN" install --cask "$1"; }
nb_uninstall_cask() { "$NB_BIN" remove --cask "$1" >/dev/null 2>&1 || true; }
nb_clear_cask_cache() {
    clear_cask_by_sha /opt/nanobrew/cache/blobs "$1"
    clear_cask_by_sha /opt/nanobrew/store       "$1"
}

# zb (zerobrew) — no cask support. Mark unsupported by returning nonzero
# from the install function; the bench treats that as "skip / not measured".
zb_install_cask()   { return 1; }
zb_uninstall_cask() { :; }
zb_clear_cask_cache() { :; }

# mt (malt) — autodetects casks; same `install`/`uninstall` verbs as formulae.
mt_install_cask()   { "$MT_BIN" install --cask "$1" 2>/dev/null || "$MT_BIN" install "$1"; }
mt_uninstall_cask() { "$MT_BIN" uninstall "$1" >/dev/null 2>&1 || true; }
mt_clear_cask_cache() {
    local prefix="${MALT_PREFIX:-/opt/malt}"
    clear_cask_by_sha "$prefix/cache/downloads" "$1"
    clear_cask_by_sha "$prefix/store"           "$1"
    clear_cask_by_sha "$prefix/store-relocated" "$1"
    clear_cask_by_sha "$prefix/Caskroom"        "$1"
}

# ── Generic helpers ───────────────────────────────────────────────────

# Time a command in milliseconds. Suppresses stdout/stderr so we measure
# wall-clock of the command itself.
time_cmd_ms() {
    local secs
    secs=$( { TIMEFORMAT='%R'; time "$@" >/dev/null 2>&1; } 2>&1 )
    awk "BEGIN {printf \"%d\", $secs * 1000}"
}

# ── Correctness checks ───────────────────────────────────────────────
# Verify that a tool's "install" produced a usable result. The point is to
# catch the failure modes a fast/minimal install path is most likely to hit:
#  - Mach-O install_names still pointing at @@HOMEBREW_PREFIX@@ placeholders
#  - Codesignature invalidated by patching (binary gets killed-9 on launch)
#  - Missing symlinks in the tool's bin dir
# A pass means "the binary runs / the library has no unresolved placeholders."
# A fail does NOT necessarily mean the tool is broken — it could be that this
# bench's prefix-discovery is wrong for that tool. Treat as a strong hint.

# Map each tool to its install prefix (where bin/, lib/, Cellar/ live).
tool_prefix() {
    case "$1" in
        brew|bru) echo "${HOMEBREW_PREFIX:-/opt/homebrew}" ;;
        nb)       echo "/opt/nanobrew/prefix" ;;
        zb)       echo "/opt/zerobrew" ;;
        mt)       echo "${MALT_PREFIX:-/opt/malt}" ;;
    esac
}

# Returns 0 on pass, 1 on fail. Silent on success; prints a one-line diagnosis
# on failure to stderr.
#
# Each formula gets two layers of check:
#   1. Structural: the artifact (binary or dylib) exists, runs --version, and
#      has no unresolved @@HOMEBREW_PREFIX@@ placeholders in its load
#      commands — catches broken codesign / missing relocation.
#   2. Functional: a real command that exercises plugins, data files, or
#      pkg-config metadata. Catches tools that skip post_install side effects
#      (tessdata not extracted, .pc not patched, schemas not compiled).
correctness_check() {
    local tool=$1 formula=$2
    local prefix; prefix=$(tool_prefix "$tool")
    if [ -z "$prefix" ] || [ ! -d "$prefix" ]; then
        echo "    correctness[$tool/$formula]: prefix not found ($prefix)" >&2
        return 1
    fi

    case "$formula" in
        libsodium)
            local dylib pc
            dylib=$(/usr/bin/find "$prefix" -path "*libsodium*.dylib" -type f 2>/dev/null | /usr/bin/head -1)
            if [ -z "$dylib" ]; then
                echo "    correctness[$tool/libsodium]: dylib not found under $prefix" >&2
                return 1
            fi
            if /usr/bin/otool -L "$dylib" 2>/dev/null | /usr/bin/grep -qE '@@'; then
                echo "    correctness[$tool/libsodium]: unresolved @@PLACEHOLDER@@ in $dylib" >&2
                return 1
            fi
            # Functional: pkg-config file must exist and have its placeholders
            # rewritten. brew + bru produce libsodium.pc with the real prefix.
            pc=$(/usr/bin/find "$prefix" -path "*lib/pkgconfig/libsodium.pc" -type f 2>/dev/null | /usr/bin/head -1)
            if [ -z "$pc" ]; then
                echo "    correctness[$tool/libsodium]: pkg-config file libsodium.pc not found under $prefix" >&2
                return 1
            fi
            if /usr/bin/grep -qE '@@' "$pc"; then
                echo "    correctness[$tool/libsodium]: unresolved placeholder in $pc" >&2
                return 1
            fi
            return 0
            ;;
        ffmpeg)
            local bin="$prefix/bin/ffmpeg"
            local probe="$prefix/bin/ffprobe"
            if [ ! -x "$bin" ]; then
                echo "    correctness[$tool/ffmpeg]: $bin not executable" >&2
                return 1
            fi
            if ! "$bin" -version >/dev/null 2>&1; then
                echo "    correctness[$tool/ffmpeg]: -version failed (codesign/dyld?)" >&2
                return 1
            fi
            # Companion: ffprobe ships in the same bottle. If it's missing,
            # the bottle wasn't fully linked.
            if [ ! -x "$probe" ]; then
                echo "    correctness[$tool/ffmpeg]: ffprobe missing at $probe" >&2
                return 1
            fi
            # pkg-config files: 7 libav*.pc files ship in the bottle. Each one
            # must have @@HOMEBREW_PREFIX@@ rewritten to a real path.
            local pc_files placeholder_pcs
            pc_files=$(/usr/bin/find "$prefix" -path "*lib/pkgconfig/libav*.pc" 2>/dev/null)
            if [ -z "$pc_files" ]; then
                echo "    correctness[$tool/ffmpeg]: libav*.pc files not found under $prefix" >&2
                return 1
            fi
            placeholder_pcs=$(echo "$pc_files" | /usr/bin/xargs /usr/bin/grep -lE '@@' 2>/dev/null | /usr/bin/head -1)
            if [ -n "$placeholder_pcs" ]; then
                echo "    correctness[$tool/ffmpeg]: unresolved placeholder in $placeholder_pcs" >&2
                return 1
            fi
            # Functional: -filters loads libavfilter and enumerates plugins.
            local n
            n=$("$bin" -hide_banner -filters 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')
            if [ "${n:-0}" -lt 50 ]; then
                echo "    correctness[$tool/ffmpeg]: -filters listed only ${n:-0} lines (expected >50)" >&2
                return 1
            fi
            # Functional: actually transcode a generated test pattern to PNG.
            # Exercises libavfilter (lavfi source) + libavcodec (png encoder)
            # + libavformat (image2 muxer) + libswscale (rgb→png convert).
            # A broken plugin chain or missing codec fails here even when
            # -filters passes.
            local tmp out rc
            tmp=$(/usr/bin/mktemp -d)
            out="$tmp/probe.png"
            "$bin" -hide_banner -loglevel error \
                -f lavfi -i "color=size=8x8:duration=0.1" \
                -frames:v 1 -y "$out" >/dev/null 2>&1
            rc=$?
            if [ "$rc" -ne 0 ] || [ ! -s "$out" ]; then
                echo "    correctness[$tool/ffmpeg]: transcode of test pattern → PNG failed (rc=$rc, size=$(/usr/bin/stat -f%z "$out" 2>/dev/null || echo missing))" >&2
                /bin/rm -rf "$tmp"
                return 1
            fi
            /bin/rm -rf "$tmp"
            return 0
            ;;
        duckdb)
            local bin="$prefix/bin/duckdb"
            if [ ! -x "$bin" ]; then
                echo "    correctness[$tool/duckdb]: $bin not executable" >&2
                return 1
            fi
            if ! "$bin" --version >/dev/null 2>&1; then
                echo "    correctness[$tool/duckdb]: --version failed" >&2
                return 1
            fi
            # Functional 1: execute a query end-to-end.
            local out
            out=$("$bin" -c "SELECT 1+1 AS r;" 2>&1 || true)
            if ! echo "$out" | /usr/bin/grep -qE '\b2\b'; then
                echo "    correctness[$tool/duckdb]: SELECT 1+1 did not return 2" >&2
                return 1
            fi
            # libduckdb.dylib must ship + have a real install_name (anyone
            # embedding duckdb in C/C++ links against it).
            local dylib
            dylib=$(/usr/bin/find "$prefix" -name "libduckdb.dylib" -type f 2>/dev/null | /usr/bin/head -1)
            if [ -z "$dylib" ]; then
                echo "    correctness[$tool/duckdb]: libduckdb.dylib not shipped (embedding broken)" >&2
                return 1
            fi
            if /usr/bin/otool -D "$dylib" 2>/dev/null | /usr/bin/grep -qE '@@'; then
                echo "    correctness[$tool/duckdb]: libduckdb.dylib install_name has unresolved placeholder" >&2
                return 1
            fi
            # Public header for C/C++ embedding must be installed.
            local hdr
            hdr=$(/usr/bin/find "$prefix" -name "duckdb.hpp" -type f 2>/dev/null | /usr/bin/head -1)
            if [ -z "$hdr" ]; then
                echo "    correctness[$tool/duckdb]: duckdb.hpp header missing (embedding broken)" >&2
                return 1
            fi
            # CMake config — required for find_package(DuckDB). Brew installs
            # 4 .cmake files; check at least one exists and has no @@ left.
            local cmake_files cmake_placeholder
            cmake_files=$(/usr/bin/find "$prefix" -path "*lib/cmake/DuckDB/*.cmake" 2>/dev/null)
            if [ -z "$cmake_files" ]; then
                echo "    correctness[$tool/duckdb]: lib/cmake/DuckDB/*.cmake missing (find_package broken)" >&2
                return 1
            fi
            cmake_placeholder=$(echo "$cmake_files" | /usr/bin/xargs /usr/bin/grep -lE '@@' 2>/dev/null | /usr/bin/head -1)
            if [ -n "$cmake_placeholder" ]; then
                echo "    correctness[$tool/duckdb]: unresolved placeholder in $cmake_placeholder" >&2
                return 1
            fi
            # Functional 2: statically-linked parquet extension round-trip.
            local tmp pq_out
            tmp=$(/usr/bin/mktemp -d)
            pq_out=$("$bin" -c "COPY (SELECT 42 AS x) TO '$tmp/t.parquet'; SELECT x FROM '$tmp/t.parquet';" 2>&1 || true)
            if ! echo "$pq_out" | /usr/bin/grep -qE '\b42\b'; then
                echo "    correctness[$tool/duckdb]: parquet round-trip failed (extension broken?)" >&2
                /bin/rm -rf "$tmp"
                return 1
            fi
            /bin/rm -rf "$tmp"
            # Functional 3: statically-linked json extension function.
            local json_out
            json_out=$("$bin" -c "SELECT json_extract('{\"a\":42}', 'a') AS v;" 2>&1 || true)
            if ! echo "$json_out" | /usr/bin/grep -qE '\b42\b'; then
                echo "    correctness[$tool/duckdb]: json_extract did not return 42 (json extension broken)" >&2
                return 1
            fi
            return 0
            ;;
        tesseract)
            local bin="$prefix/bin/tesseract"
            if [ ! -x "$bin" ]; then
                echo "    correctness[$tool/tesseract]: $bin not executable" >&2
                return 1
            fi
            if ! "$bin" --version >/dev/null 2>&1; then
                echo "    correctness[$tool/tesseract]: --version failed" >&2
                return 1
            fi
            # Functional: --list-langs reads tessdata; the brew formula bundles
            # at least eng + osd. A tool that skipped extracting share/tessdata
            # will list zero languages.
            local out
            out=$("$bin" --list-langs 2>&1 || true)
            if ! echo "$out" | /usr/bin/grep -qE '^eng$|^osd$'; then
                echo "    correctness[$tool/tesseract]: --list-langs found no eng/osd (tessdata missing?)" >&2
                return 1
            fi
            return 0
            ;;
        act)
            local bin="$prefix/bin/act"
            if [ ! -x "$bin" ]; then
                echo "    correctness[$tool/act]: $bin not executable" >&2
                return 1
            fi
            if ! "$bin" --version >/dev/null 2>&1; then
                echo "    correctness[$tool/act]: --version failed (codesign/dyld?)" >&2
                return 1
            fi
            # Functional: --help prints command structure. act is a self-
            # contained Go binary so it doesn't have many ways to be broken,
            # but a corrupted/truncated install would fail to parse args.
            local help
            help=$("$bin" --help 2>&1 || true)
            if ! echo "$help" | /usr/bin/grep -qiE 'usage:|github actions'; then
                echo "    correctness[$tool/act]: --help did not show expected usage banner" >&2
                return 1
            fi
            return 0
            ;;
        rectangle)
            # Cask: .app bundle lives in /Applications. The tool may also
            # symlink/install into its own Caskroom — we accept either path.
            # Use find rather than glob expansion so missing intermediate
            # dirs don't trip nounset or bash 3.2 glob behavior.
            local app=""
            if [ -d "/Applications/Rectangle.app" ]; then
                app="/Applications/Rectangle.app"
            else
                app=$(/usr/bin/find "$prefix/Caskroom" "$prefix/Cask" \
                    -maxdepth 3 -type d -name "Rectangle.app" 2>/dev/null | /usr/bin/head -1)
            fi
            if [ -z "$app" ] || [ ! -d "$app" ]; then
                echo "    correctness[$tool/rectangle]: Rectangle.app not found in /Applications or $prefix" >&2
                return 1
            fi
            # The Mach-O binary inside the bundle must exist and be executable.
            local bin="$app/Contents/MacOS/Rectangle"
            if [ ! -x "$bin" ]; then
                echo "    correctness[$tool/rectangle]: $bin missing or not executable" >&2
                return 1
            fi
            # Info.plist must be present (otherwise macOS won't recognise the
            # app at all — a sign of an interrupted/incomplete install).
            if [ ! -f "$app/Contents/Info.plist" ]; then
                echo "    correctness[$tool/rectangle]: Info.plist missing in $app" >&2
                return 1
            fi
            # Code signature must be valid (notarised vendor app — if the tool
            # mangled the bundle during install, signature verification fails).
            if ! /usr/bin/codesign --verify --no-strict "$app" 2>/dev/null; then
                echo "    correctness[$tool/rectangle]: codesign --verify failed for $app" >&2
                return 1
            fi
            return 0
            ;;
        *)
            # Generic fallback for any new formula added to FORMULAE.
            local bin="$prefix/bin/$formula"
            [ -x "$bin" ] || { echo "    correctness[$tool/$formula]: $bin not executable" >&2; return 1; }
            "$bin" --version >/dev/null 2>&1 || { echo "    correctness[$tool/$formula]: --version failed" >&2; return 1; }
            return 0
            ;;
    esac
}

# Pre-install brew deps once so every tool measures only the target install.
# Individual dep install failures are reported to stderr but don't abort
# the bench — the target install may still succeed against partial deps.
ensure_brew_deps() {
    local formula="$1"
    local deps
    deps=$(brew deps "$formula" 2>/dev/null | tr '\n' ' ') || return 0
    [ -z "$deps" ] && return 0
    if $DRY_RUN; then
        step "[dry-run] pre-install deps for $formula ($(echo "$deps" | wc -w | tr -d ' ') pkgs)"
        return 0
    fi
    for dep in $deps; do
        if ! brew list --formula "$dep" &>/dev/null; then
            if ! brew install "$dep" >/dev/null 2>&1; then
                echo "  (warning: brew install $dep failed; continuing)" >&2
            fi
        fi
    done
}

# ── Step 1: read versions ────────────────────────────────────────────

log "Step 1 — read versions"
VERSIONS=()
PRESENT=()
for tool in "${TOOL_ORDER[@]}"; do
    if "${tool}_present"; then
        PRESENT+=(1)
        VERSIONS+=("$("${tool}_version" 2>/dev/null || echo '?')")
    elif $DRY_RUN; then
        # Render every tool in dry-run mode with a placeholder so the chart
        # shape is visible without running anything.
        PRESENT+=(1)
        VERSIONS+=("—")
    else
        PRESENT+=(0)
        VERSIONS+=("not installed")
    fi
done

for i in "${!TOOL_ORDER[@]}"; do
    print_version_row "${TOOL_ORDER[$i]}" "${VERSIONS[$i]}"
done
log ""

# Surface missing-tool warning. The bench will still produce SVGs with
# greyed-out rows, but the user should know contenders is the fix.
missing=()
for i in "${!TOOL_ORDER[@]}"; do
    [ "${PRESENT[$i]}" = "0" ] && missing+=("${TOOL_ORDER[$i]}")
done
if [ ${#missing[@]} -gt 0 ]; then
    log "Warning: ${missing[*]} not installed — rows will render as 'not measured'."
    log "         Run: bash $SCRIPT_DIR/bench_contenders.sh"
    log ""
fi

# ── Step 2: benchmark cold + warm installs per (tool, package) ───────

# Build unified package list with a parallel kind array.
# PKG_KIND_ARR[$i] = "formula" or "cask"
PKG_ARR=()
PKG_KIND_ARR=()
for f in $FORMULAE; do PKG_ARR+=("$f"); PKG_KIND_ARR+=("formula"); done
for c in $CASKS;    do PKG_ARR+=("$c"); PKG_KIND_ARR+=("cask");    done
NPKGS=${#PKG_ARR[@]}
NTOOLS=${#TOOL_ORDER[@]}

COLD_TABLE=()
WARM_TABLE=()
# CORRECT_TABLE: -1 = not checked, 0 = fail, 1 = pass.
CORRECT_TABLE=()
for ((init_i=0; init_i < NTOOLS * NPKGS; init_i++)); do
    COLD_TABLE+=(0)
    WARM_TABLE+=(0)
    CORRECT_TABLE+=(-1)
done

set_cold()    { local ti=$1 pj=$2 v=$3; COLD_TABLE[$((ti * NPKGS + pj))]=$v; }
set_warm()    { local ti=$1 pj=$2 v=$3; WARM_TABLE[$((ti * NPKGS + pj))]=$v; }
set_correct() { local ti=$1 pj=$2 v=$3; CORRECT_TABLE[$((ti * NPKGS + pj))]=$v; }
get_cold()    { local ti=$1 pj=$2; echo "${COLD_TABLE[$((ti * NPKGS + pj))]:-0}"; }
get_warm()    { local ti=$1 pj=$2; echo "${WARM_TABLE[$((ti * NPKGS + pj))]:-0}"; }
get_correct() { local ti=$1 pj=$2; echo "${CORRECT_TABLE[$((ti * NPKGS + pj))]:--1}"; }

log "Step 2 — install benchmark"
log "Formulae: $FORMULAE"
log "Casks:    $CASKS"
log ""

for ti in "${!TOOL_ORDER[@]}"; do
    tool="${TOOL_ORDER[$ti]}"
    if [ "${PRESENT[$ti]}" != "1" ]; then
        log "[$tool] not present — skipping"
        continue
    fi

    log "[$tool] v${VERSIONS[$ti]}"

    for pj in "${!PKG_ARR[@]}"; do
        pkg="${PKG_ARR[$pj]}"
        kind="${PKG_KIND_ARR[$pj]}"

        # zerobrew has no cask support — mark as not-measured (grey) and
        # skip rather than calling a stub that would mislabel as BROKEN.
        if [ "$kind" = "cask" ] && [ "$tool" = "zb" ]; then
            set_correct $ti $pj -1
            step "$pkg ($kind) → not supported by $tool"
            continue
        fi

        # Dispatch to formula or cask flavour of the per-tool functions.
        case "$kind" in
            formula)
                install_fn="${tool}_install_pkg"
                uninstall_fn="${tool}_uninstall_pkg"
                clear_fn="${tool}_clear_cache"
                ;;
            cask)
                install_fn="${tool}_install_cask"
                uninstall_fn="${tool}_uninstall_cask"
                clear_fn="${tool}_clear_cask_cache"
                ;;
        esac

        # Pre-install brew deps for formulae only (casks don't have a
        # transitive Homebrew dep tree to warm).
        if [ "$kind" = "formula" ] && { [ "$tool" = "brew" ] || [ "$tool" = "bru" ]; }; then
            ensure_brew_deps "$pkg"
        fi

        if $DRY_RUN; then
            case "$tool" in
                bru)  base_c=600;  base_w=250  ;;
                nb)   base_c=1800; base_w=350  ;;
                zb)   base_c=1500; base_w=400  ;;
                mt)   base_c=1700; base_w=380  ;;
                brew) base_c=2200; base_w=1100 ;;
            esac
            mult=$((pj + 1))
            set_cold $ti $pj $((base_c * mult / 2 + base_c))
            set_warm $ti $pj $((base_w * mult / 3 + base_w))
            case "$tool" in
                nb|mt) set_correct $ti $pj 0 ;;
                *)     set_correct $ti $pj 1 ;;
            esac
            # zb has no cask support — leave row as not-measured in dry-run.
            if [ "$kind" = "cask" ] && [ "$tool" = "zb" ]; then
                set_cold $ti $pj 0
                set_warm $ti $pj 0
                set_correct $ti $pj -1
            fi
            step "[dry-run] $tool $pkg ($kind) → cold=$(get_cold $ti $pj)ms warm=$(get_warm $ti $pj)ms"
            continue
        fi

        # Cold install.
        "$uninstall_fn" "$pkg" || true
        "$clear_fn"     "$pkg" || true
        if ! cold=$(time_cmd_ms "$install_fn" "$pkg"); then
            cold=0
            echo "  (warning: $tool cold install $pkg failed)" >&2
        fi

        # Warm install.
        "$uninstall_fn" "$pkg" || true
        if ! warm=$(time_cmd_ms "$install_fn" "$pkg"); then
            warm=0
            echo "  (warning: $tool warm install $pkg failed)" >&2
        fi

        # Correctness check while the install is still on disk.
        if correctness_check "$tool" "$pkg"; then
            set_correct $ti $pj 1
            ok_mark="ok"
        else
            set_correct $ti $pj 0
            ok_mark="BROKEN"
        fi

        "$uninstall_fn" "$pkg" || true

        set_cold $ti $pj $cold
        set_warm $ti $pj $warm
        step "$pkg ($kind) → cold=${cold}ms warm=${warm}ms [$ok_mark]"
    done
done
log ""

# ── Step 3: render one SVG per package ───────────────────────────────

OUTPUT_PREFIX="${SVG_OUTPUT%.svg}"
[ "$OUTPUT_PREFIX" = "$SVG_OUTPUT" ] && OUTPUT_PREFIX="$SVG_OUTPUT"

# Polished palette (Tailwind-inspired).
WARM_FILL="#FBBF24"        # amber-400
COLD_FILL="#3B82F6"        # blue-500
INK="#0F172A"              # slate-900
INK_MUTED="#64748B"        # slate-500
INK_FAINT="#94A3B8"        # slate-400
DIVIDER="#E2E8F0"          # slate-200
BG="#FFFFFF"
LABEL_ON_FILL="#FFFFFF"

# Per-package SVG layout.
SVG_W=760
PAD_X=32
TITLE_Y=44
SUBTITLE_Y=68
HEADER_BOTTOM=92
LABEL_W=120
BAR_X=$((PAD_X + LABEL_W + 16))
BAR_MAX_W=$((SVG_W - BAR_X - PAD_X))
ROW_H=46
BAR_H=26
LEGEND_PAD=24
SVG_H=$((HEADER_BOTTOM + 16 + NTOOLS * ROW_H + LEGEND_PAD * 2 + 8))

format_ms() {
    local ms=$1
    if [ "$ms" -lt 1000 ]; then
        printf '%dms' "$ms"
    else
        awk "BEGIN {printf \"%.1fs\", $ms/1000}"
    fi
}

# Estimate the pixel width of a rendered label so we can decide whether it
# fits inside its bar segment. 11px semibold ≈ 6.5px per char + 8px padding.
label_width_px() {
    local text="$1"
    local n=${#text}
    echo $(( n * 7 + 8 ))
}

render_package_svg() {
    local pj=$1
    local pkg="${PKG_ARR[$pj]}"

    local max_total=0
    for ti in "${!TOOL_ORDER[@]}"; do
        local total=$(( $(get_warm $ti $pj) + $(get_cold $ti $pj) ))
        [ $total -gt $max_total ] && max_total=$total
    done
    [ $max_total -eq 0 ] && max_total=1

    cat <<SVG_HEAD
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $SVG_W $SVG_H" width="$SVG_W" height="$SVG_H">
  <defs>
    <style>
      .t-title    { font: 600 22px -apple-system, BlinkMacSystemFont, "Inter", "Segoe UI", Roboto, system-ui, sans-serif; fill: $INK; }
      .t-subtitle { font: 400 12px -apple-system, BlinkMacSystemFont, "Inter", "Segoe UI", Roboto, system-ui, sans-serif; fill: $INK_MUTED; letter-spacing: 0.02em; }
      .t-tool     { font: 600 13px -apple-system, BlinkMacSystemFont, "Inter", "Segoe UI", Roboto, system-ui, sans-serif; fill: $INK; }
      .t-ver      { font: 400 11px -apple-system, BlinkMacSystemFont, "Inter", "Segoe UI", Roboto, system-ui, sans-serif; fill: $INK_FAINT; }
      .t-label-on { font: 600 11px -apple-system, BlinkMacSystemFont, "Inter", "Segoe UI", Roboto, system-ui, sans-serif; fill: $LABEL_ON_FILL; }
      .t-label-off{ font: 600 11px -apple-system, BlinkMacSystemFont, "Inter", "Segoe UI", Roboto, system-ui, sans-serif; fill: $INK; }
      .t-warm-out { font: 600 11px -apple-system, BlinkMacSystemFont, "Inter", "Segoe UI", Roboto, system-ui, sans-serif; fill: #B45309; }
      .t-cold-out { font: 600 11px -apple-system, BlinkMacSystemFont, "Inter", "Segoe UI", Roboto, system-ui, sans-serif; fill: #1D4ED8; }
      .t-skip     { font: 400 12px -apple-system, BlinkMacSystemFont, "Inter", "Segoe UI", Roboto, system-ui, sans-serif; fill: $INK_FAINT; font-style: italic; }
      .t-legend   { font: 500 11px -apple-system, BlinkMacSystemFont, "Inter", "Segoe UI", Roboto, system-ui, sans-serif; fill: $INK_MUTED; letter-spacing: 0.02em; }
      .t-status-glyph { font: 700 9px -apple-system, BlinkMacSystemFont, "Inter", "Segoe UI", Roboto, system-ui, sans-serif; }
    </style>
  </defs>
  <rect width="100%" height="100%" fill="$BG"/>
  <title>$pkg — install benchmark</title>
  <text class="t-title" x="$PAD_X" y="$TITLE_Y">$pkg</text>
  <text class="t-subtitle" x="$PAD_X" y="$SUBTITLE_Y">INSTALL BENCHMARK · COLD VS WARM CACHE</text>
  <line x1="$PAD_X" y1="$HEADER_BOTTOM" x2="$((SVG_W - PAD_X))" y2="$HEADER_BOTTOM" stroke="$DIVIDER" stroke-width="1"/>
SVG_HEAD

    local row_y=$((HEADER_BOTTOM + 24))
    for ti in "${!TOOL_ORDER[@]}"; do
        local tool="${TOOL_ORDER[$ti]}"
        local ver="${VERSIONS[$ti]}"
        local warm=$(get_warm $ti $pj)
        local cold=$(get_cold $ti $pj)
        local correct=$(get_correct $ti $pj)

        local ver_text
        case "$ver" in
            [0-9]*) ver_text="v$ver" ;;
            *)      ver_text="$ver" ;;
        esac

        local tool_x=$PAD_X
        local name_y=$((row_y + 10))
        local ver_y=$((row_y + 26))
        local bar_y=$((row_y + (ROW_H - BAR_H) / 2))
        local label_baseline=$((bar_y + BAR_H / 2 + 4))

        # Status indicator — a small colored dot to the right of the tool
        # name. Green = correctness check passed, red = failed, faint gray =
        # not measured (tool wasn't present).
        local status_cx=$((tool_x + 64))
        local status_cy=$((name_y - 4))
        local status_fill status_glyph status_glyph_color
        case "$correct" in
            1)  status_fill="#22C55E"; status_glyph="✓"; status_glyph_color="#FFFFFF" ;;
            0)  status_fill="#EF4444"; status_glyph="!"; status_glyph_color="#FFFFFF" ;;
            *)  status_fill="#CBD5E1"; status_glyph="";  status_glyph_color="#FFFFFF" ;;
        esac

        cat <<ROW_HEAD
  <g>
    <text class="t-tool" x="$tool_x" y="$name_y">$tool</text>
    <text class="t-ver"  x="$tool_x" y="$ver_y">$ver_text</text>
    <circle cx="$status_cx" cy="$status_cy" r="6" fill="$status_fill"/>
    <text class="t-status-glyph" x="$status_cx" y="$((status_cy + 4))" text-anchor="middle" fill="$status_glyph_color">$status_glyph</text>
ROW_HEAD

        if [ "${PRESENT[$ti]}" != "1" ] || { [ "$warm" -eq 0 ] && [ "$cold" -eq 0 ]; }; then
            cat <<ROW_SKIP
    <text class="t-skip" x="$BAR_X" y="$label_baseline">not measured</text>
  </g>
ROW_SKIP
            row_y=$((row_y + ROW_H))
            continue
        fi

        local warm_w cold_w
        warm_w=$(awk "BEGIN {printf \"%d\", $warm / $max_total * $BAR_MAX_W}")
        cold_w=$(awk "BEGIN {printf \"%d\", $cold / $max_total * $BAR_MAX_W}")
        [ "$warm_w" -lt 1 ] && warm_w=0
        [ "$cold_w" -lt 1 ] && cold_w=0

        local warm_label cold_label warm_lbl_w cold_lbl_w
        warm_label=$(format_ms $warm)
        cold_label=$(format_ms $cold)
        warm_lbl_w=$(label_width_px "$warm_label")
        cold_lbl_w=$(label_width_px "$cold_label")

        local cold_x=$((BAR_X + warm_w + 2))
        local bar_end=$((cold_x + cold_w))
        local outside_x=$((bar_end + 8))
        local warm_inside=0 cold_inside=0

        if [ "$warm_w" -gt 0 ]; then
            cat <<WARM_SEG
    <rect x="$BAR_X" y="$bar_y" width="$warm_w" height="$BAR_H" rx="4" ry="4" fill="$WARM_FILL"/>
WARM_SEG
            if [ "$warm_w" -ge "$warm_lbl_w" ]; then
                warm_inside=1
                local cx=$((BAR_X + warm_w / 2))
                cat <<WARM_LBL
    <text class="t-label-off" x="$cx" y="$label_baseline" text-anchor="middle">$warm_label</text>
WARM_LBL
            fi
        fi

        if [ "$cold_w" -gt 0 ]; then
            cat <<COLD_SEG
    <rect x="$cold_x" y="$bar_y" width="$cold_w" height="$BAR_H" rx="4" ry="4" fill="$COLD_FILL"/>
COLD_SEG
            if [ "$cold_w" -ge "$cold_lbl_w" ]; then
                cold_inside=1
                local cx=$((cold_x + cold_w / 2))
                cat <<COLD_LBL
    <text class="t-label-on" x="$cx" y="$label_baseline" text-anchor="middle">$cold_label</text>
COLD_LBL
            fi
        fi

        if [ "$warm_inside" -eq 0 ] && [ "$warm_w" -gt 0 ]; then
            cat <<WARM_OUT
    <text class="t-warm-out" x="$outside_x" y="$label_baseline">$warm_label</text>
WARM_OUT
            outside_x=$((outside_x + warm_lbl_w + 6))
        fi
        if [ "$cold_inside" -eq 0 ] && [ "$cold_w" -gt 0 ]; then
            cat <<COLD_OUT
    <text class="t-cold-out" x="$outside_x" y="$label_baseline">$cold_label</text>
COLD_OUT
        fi

        cat <<ROW_END
  </g>
ROW_END
        row_y=$((row_y + ROW_H))
    done

    local legend_y=$((row_y + LEGEND_PAD))
    local legend_x=$PAD_X
    cat <<LEGEND
  <g>
    <rect x="$legend_x" y="$((legend_y - 9))" width="12" height="12" rx="2" ry="2" fill="$WARM_FILL"/>
    <text class="t-legend" x="$((legend_x + 18))" y="$((legend_y + 1))">CACHE WARM</text>
    <rect x="$((legend_x + 130))" y="$((legend_y - 9))" width="12" height="12" rx="2" ry="2" fill="$COLD_FILL"/>
    <text class="t-legend" x="$((legend_x + 148))" y="$((legend_y + 1))">CACHE COLD</text>
    <circle cx="$((legend_x + 266))" cy="$((legend_y - 3))" r="6" fill="#22C55E"/>
    <text class="t-status-glyph" x="$((legend_x + 266))" y="$((legend_y + 1))" text-anchor="middle" fill="#FFFFFF">✓</text>
    <text class="t-legend" x="$((legend_x + 278))" y="$((legend_y + 1))">VERIFIED</text>
    <circle cx="$((legend_x + 348))" cy="$((legend_y - 3))" r="6" fill="#EF4444"/>
    <text class="t-status-glyph" x="$((legend_x + 348))" y="$((legend_y + 1))" text-anchor="middle" fill="#FFFFFF">!</text>
    <text class="t-legend" x="$((legend_x + 360))" y="$((legend_y + 1))">BROKEN</text>
  </g>
</svg>
LEGEND
}

log "Step 3 — render SVGs"
WRITTEN=()
for pj in "${!PKG_ARR[@]}"; do
    pkg="${PKG_ARR[$pj]}"
    out="${OUTPUT_PREFIX}-${pkg}.svg"
    render_package_svg "$pj" > "$out"
    WRITTEN+=("$out")
    step "wrote $out"
done

log ""
log "Done. ${#WRITTEN[@]} SVG(s) written."
