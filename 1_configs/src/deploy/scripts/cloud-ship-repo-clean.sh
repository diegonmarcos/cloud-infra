#!/bin/sh
set -e
CLOUD_ROOT="${CLOUD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
. "$CLOUD_ROOT/1_configs/src/deploy/scripts/cloud-ship-lib.sh"

# Clean all dist/ folders
cmd_clean() {
    log "Cleaning all dist/ folders..."
    count=0
    for d in "$SOLUTIONS_DIR"/*/dist; do
        [ -d "$d" ] || continue
        rm -rf "$d"
        count=$((count + 1))
    done
    # Also clean .result symlinks
    for r in "$SOLUTIONS_DIR"/*/.result; do
        [ -e "$r" ] && rm -f "$r"
    done
    log "Cleaned $count dist/ folders"
}

cmd_clean "$@"
