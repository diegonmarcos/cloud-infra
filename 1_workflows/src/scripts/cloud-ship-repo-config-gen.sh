#!/bin/sh
set -e
CLOUD_ROOT="${CLOUD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
. "$CLOUD_ROOT/1_workflows/src/scripts/cloud-ship-lib.sh"

# Generate cloud-topology.json/md + cloud-configs.json/md from sources
cmd_config() {
    if ! command -v tsx >/dev/null 2>&1; then
        log "SKIP: tsx not installed (npm install -g tsx)"
        return 1
    fi
    # cloud-data may be either a populated submodule (2_configs/dist/) or a
    # sibling checkout (../cloud-data/ from CLOUD_ROOT). Pick whichever has
    # the engine, env override wins.
    _cd_base="${CLOUD_DATA_DIR:-}"
    if [ -z "$_cd_base" ]; then
        for _p in "$CLOUD_ROOT/2_configs/dist" "$(dirname "$CLOUD_ROOT")/cloud-data" "/root/git/cloud-data"; do
            [ -f "$_p/1_workflows/src/scripts/cloud-data-config.ts" ] && { _cd_base="$_p"; break; }
        done
    fi
    CD_SCRIPTS="$_cd_base/1_workflows/src/scripts"
    CD_MASTER="$CD_SCRIPTS/cloud-data-config.ts"
    if [ -z "$_cd_base" ] || [ ! -f "$CD_MASTER" ]; then
        log "SKIP: cloud-data engine not found (tried 2_configs/dist, sibling, /root/git/cloud-data)"
        return 1
    fi
    log "Using cloud-data engine: $_cd_base"
    # ESM resolution ignores NODE_PATH — symlink shared node_modules so tsx finds packages
    SHARED_NM="$HOME/.node_modules/node_modules"
    if [ -d "$SHARED_NM" ] && [ ! -e "$CD_SCRIPTS/node_modules" ]; then
        ln -s "$SHARED_NM" "$CD_SCRIPTS/node_modules"
    fi
    log "Running cloud-data master (consolidated + derive)..."
    tsx "$CD_MASTER"
}

cmd_config "$@"
