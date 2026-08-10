#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/deploy/scripts/cloud-ship-orchestrate-build.sh
# ║   Engine : 1_configs/src/deploy/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

set -e
CLOUD_ROOT="${CLOUD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
. "$CLOUD_ROOT/1_configs/src/deploy/scripts/cloud-ship-lib.sh"

# Build one service (delegates to per-service build.sh)
build_service() {
    svc="$1"
    folder=$(get_service_folder "$svc")
    svc_dir="$SOLUTIONS_DIR/$folder"

    # Skip services without a build.sh
    if [ ! -f "$svc_dir/build.sh" ]; then
        log "SKIP $svc (no build.sh)"
        return 0
    fi

    # Skip local-only (terraform)
    vm=$(get_svc_prop "$svc" "vm")
    if [ "$vm" = "local" ]; then
        log "SKIP $svc (local/terraform)"
        return 0
    fi

    log "Building $svc..."
    if sh "$svc_dir/build.sh" all 2>&1; then
        log "OK $svc"
    else
        log_error "FAIL $svc"
        return 1
    fi
    echo ""
}

# Build one or all services
cmd_build() {
    service="$1"
    ok=0; fail=0; skip=0

    if [ -n "$service" ]; then
        # Build single service
        build_service "$service"
    else
        # Build all services
        log "Building all services..."
        echo ""
        get_all_services | while read -r svc; do
            build_service "$svc" || true
        done
    fi
}

# Only run when invoked directly, not when sourced
case "${0##*/}" in
    cloud-ship-orchestrate-build.sh) cmd_build "$@" ;;
esac
