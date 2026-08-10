#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/deploy/scripts/cloud-ship-repo-config-gen.sh
# ║   Engine : 1_configs/src/deploy/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

set -e
CLOUD_ROOT="${CLOUD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
. "$CLOUD_ROOT/1_configs/src/deploy/scripts/cloud-ship-lib.sh"

# Generate cloud-data configs (cloud-data-*.json + per-container build-*.json).
#
# Engine layout (current, post-2026-04 reorg):
#   cloud/1_configs/build.sh            <- universal entry (link-builds + consolidate + derive)
#   cloud/1_configs/src/engine/        <- the .ts engines (cloud-data-config.ts, derive, etc.)
#   cloud/1_configs/dist/               <- output (build-*.json, cloud-data-*.json, _cloud-data-consolidated.json)
#
# Legacy layout (pre-reorg, kept as fallback for older clones):
#   cloud-data/1_configs/src/deploy/scripts/cloud-data-config.ts
#
# Strategy: prefer the canonical 1_configs/build.sh interface. Fall back to
# the legacy direct-tsx invocation only if 1_configs/ isn't present.
cmd_config() {
    if ! command -v tsx >/dev/null 2>&1; then
        log "SKIP: tsx not installed (npm install -g tsx)"
        return 1
    fi
    # ── Path A (current): cloud/1_configs/build.sh ──────────────────
    if [ -x "$CLOUD_ROOT/1_configs/build.sh" ]; then
        log "Using engine: 1_configs/build.sh all"
        # ESM resolution ignores NODE_PATH — symlink shared node_modules so
        # tsx finds packages from inside the engine dir.
        SHARED_NM="$HOME/.node_modules/node_modules"
        ENGINES_DIR="$CLOUD_ROOT/1_configs/src/engine"
        if [ -d "$SHARED_NM" ] && [ ! -e "$ENGINES_DIR/node_modules" ]; then
            ln -s "$SHARED_NM" "$ENGINES_DIR/node_modules"
        fi
        # build.sh all = link-builds + consolidate + derive (full pipeline).
        # Output lands in cloud/1_configs/dist/, which the next steps
        # (orchestrate-gen-configs) commit + push to cloud-data submodule.
        bash "$CLOUD_ROOT/1_configs/build.sh" all
        return 0
    fi
    # ── Path B (legacy fallback): cloud-data submodule with its own engine ──
    # Workspace root: env override > /root/git default (CI mount path).
    _ws="${WORKSPACE:-/root/git}"
    _cd_base="${CLOUD_DATA_DIR:-}"
    if [ -z "$_cd_base" ]; then
        for _p in "$CLOUD_ROOT/1_configs/dist" "$(dirname "$CLOUD_ROOT")/cloud-data" "$_ws/cloud-data"; do
            [ -f "$_p/1_configs/src/deploy/scripts/cloud-data-config.ts" ] && { _cd_base="$_p"; break; }
        done
    fi
    CD_SCRIPTS="$_cd_base/1_configs/src/deploy/scripts"
    CD_MASTER="$CD_SCRIPTS/cloud-data-config.ts"
    if [ -z "$_cd_base" ] || [ ! -f "$CD_MASTER" ]; then
        log "SKIP: neither 1_configs/build.sh nor cloud-data legacy engine found"
        log "  1_configs/build.sh:    $CLOUD_ROOT/1_configs/build.sh"
        log "  legacy candidates:    $CLOUD_ROOT/1_configs/dist, $(dirname "$CLOUD_ROOT")/cloud-data, $_ws/cloud-data"
        return 1
    fi
    log "Using legacy cloud-data engine: $_cd_base"
    SHARED_NM="$HOME/.node_modules/node_modules"
    if [ -d "$SHARED_NM" ] && [ ! -e "$CD_SCRIPTS/node_modules" ]; then
        ln -s "$SHARED_NM" "$CD_SCRIPTS/node_modules"
    fi
    log "Running cloud-data master (consolidated + derive)..."
    tsx "$CD_MASTER"
}

cmd_config "$@"
