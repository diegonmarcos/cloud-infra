#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/deploy/scripts/cloud-ship-orchestrate-profile.sh
# ║   Engine : 1_configs/src/deploy/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

set -e
CLOUD_ROOT="${CLOUD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
. "$CLOUD_ROOT/1_configs/src/deploy/scripts/cloud-ship-lib.sh"

# Profile ship — deploy services by tier from a profile JSON
cmd_profile_ship() {
    [ -z "${CLOUD_PROFILE:-}" ] && { log_error "CLOUD_PROFILE not set. Usage: CLOUD_PROFILE=<name> ./cloud-ship-orchestrate-profile.sh"; exit 1; }
    export CLOUD_PROFILE FORCE_DEPLOY=1
    PF="$CLOUD_ROOT/build_${CLOUD_PROFILE}.json"
    [ ! -f "$PF" ] && { log_error "build_${CLOUD_PROFILE}.json not found"; exit 1; }
    log "=== Profile: $CLOUD_PROFILE ==="
    for tier in 1 2 3; do
        [ -n "${TIER:-}" ] && [ "$TIER" != "$tier" ] && continue
        log "=== Tier $tier ==="
        for svc in $(jq -r ".tiers.\"$tier\"[]" "$PF"); do
            SVC_DIR=$(find "$SOLUTIONS_DIR" -maxdepth 1 -name "*_$svc" -type d | head -1)
            if [ -d "$SVC_DIR" ]; then
                log "Shipping $svc..."
                "$SVC_DIR/build.sh" ship || log_warn "FAIL: $svc"
            else
                log_warn "Not found: $svc"
            fi
        done
        log "=== Tier $tier complete ==="
    done
}

cmd_profile_ship "$@"
