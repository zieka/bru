#!/bin/bash
# bench_contenders.sh — install or self-update every package manager that
# `bench_chart.sh` benchmarks against. Idempotent: skips work that's already
# done, runs the upstream self-update path when a tool is already present.
#
# Usage:
#   bash test/benchmark/bench_contenders.sh
#   bash test/benchmark/bench_contenders.sh --dry-run
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/benchmark/_bench_common.sh
. "$SCRIPT_DIR/_bench_common.sh"

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then DRY_RUN=true; fi

# ── ensure-latest functions ──────────────────────────────────────────

brew_ensure_latest() {
    brew_present || die "brew is not installed — install via https://brew.sh first"
    log "[brew] brew update"
    if $DRY_RUN; then step "[dry-run] brew update"; return; fi
    brew update >/dev/null 2>&1 || true
}

bru_ensure_latest() {
    log "[bru] zig build -Doptimize=ReleaseFast (worktree: $PROJECT_ROOT)"
    if $DRY_RUN; then step "[dry-run] zig build -Doptimize=ReleaseFast"; return; fi
    (cd "$PROJECT_ROOT" && zig build -Doptimize=ReleaseFast)
}

nb_ensure_latest() {
    if nb_present; then
        log "[nb] $NB_BIN update"
        if $DRY_RUN; then step "[dry-run] $NB_BIN update"; return; fi
        "$NB_BIN" update >/dev/null 2>&1 || true
        return
    fi
    log "[nb] not installed — running nanobrew install script"
    if $DRY_RUN; then step "[dry-run] curl -fsSL https://nanobrew.dev/install.sh | bash"; return; fi
    curl -fsSL https://nanobrew.dev/install.sh | bash \
        || { echo "nanobrew install failed" >&2; return 1; }
    NB_BIN=""; nb_present
}

zb_ensure_latest() {
    # The official install script doubles as the updater.
    if zb_present; then
        log "[zb] re-running install script to update"
    else
        log "[zb] not installed — running install script"
    fi
    if $DRY_RUN; then step "[dry-run] curl -fsSL https://zerobrew.rs/install | bash"; return; fi
    curl -fsSL https://zerobrew.rs/install | bash \
        || { echo "zerobrew install/update failed" >&2; return 1; }
    ZB_BIN=""; zb_present
}

mt_ensure_latest() {
    # Same story as zb — install script also updates.
    if mt_present; then
        log "[mt] re-running install script to update"
    else
        log "[mt] not installed — running malt install script"
    fi
    if $DRY_RUN; then
        step "[dry-run] curl -fsSL https://raw.githubusercontent.com/indaco/malt/main/scripts/install.sh | bash"
        return
    fi
    curl -fsSL https://raw.githubusercontent.com/indaco/malt/main/scripts/install.sh | bash \
        || { echo "malt install/update failed" >&2; return 1; }
    MT_BIN=""; mt_present
}

# ── Main ─────────────────────────────────────────────────────────────

log "Installing/updating benchmark contenders..."
log ""

for tool in "${TOOL_ORDER[@]}"; do
    "${tool}_ensure_latest" || true
done

log ""
log "Final versions:"
for tool in "${TOOL_ORDER[@]}"; do
    if "${tool}_present"; then
        v=$("${tool}_version" 2>/dev/null || echo '?')
        print_version_row "$tool" "$v"
    else
        print_version_row "$tool" "not installed"
    fi
done
