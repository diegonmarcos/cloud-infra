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
    if [ ! -f "$ENGINES_DIR/gen-cloud-data.ts" ] || [ ! -f "$ENGINES_DIR/derive-cloud-data.ts" ]; then
        log "SKIP: engine sources not available locally"
        return 1
    fi
    # ESM resolution ignores NODE_PATH — symlink shared node_modules so tsx finds packages
    SHARED_NM="$HOME/.node_modules/node_modules"
    if [ -d "$SHARED_NM" ] && [ ! -e "$ENGINE_DIR/node_modules" ]; then
        ln -s "$SHARED_NM" "$ENGINE_DIR/node_modules"
    fi
    # v2 pipeline: consolidated → derivation (17 per-consumer JSONs)
    log "Generating _cloud-data-consolidated.json..."
    tsx "$ENGINES_DIR/gen-cloud-data.ts"
    log "Deriving per-consumer JSONs from consolidated..."
    tsx "$ENGINES_DIR/derive-cloud-data.ts"
}

cmd_config "$@"
