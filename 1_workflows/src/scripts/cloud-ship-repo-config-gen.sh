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
    CD_SCRIPTS="$CLOUD_ROOT/I_cloud-data/1_workflows/src/scripts"
    CD_MASTER="$CD_SCRIPTS/cloud-data-config.ts"
    if [ ! -f "$CD_MASTER" ]; then
        log "SKIP: cloud-data engine not available at $CD_MASTER"
        return 1
    fi
    # ESM resolution ignores NODE_PATH — symlink shared node_modules so tsx finds packages
    SHARED_NM="$HOME/.node_modules/node_modules"
    if [ -d "$SHARED_NM" ] && [ ! -e "$CD_SCRIPTS/node_modules" ]; then
        ln -s "$SHARED_NM" "$CD_SCRIPTS/node_modules"
    fi
    log "Running cloud-data master (consolidated + derive)..."
    tsx "$CD_MASTER"
}

cmd_config "$@"
