#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/gha/scripts/cloud-ship-orchestrate-ship.sh
# ║   Engine : 1_configs/src/gha/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

set -e
CLOUD_ROOT="${CLOUD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
. "$CLOUD_ROOT/1_configs/src/gha/scripts/cloud-ship-lib.sh"

# Source build script to get build_service()
. "$CLOUD_ROOT/1_configs/src/gha/scripts/cloud-ship-orchestrate-build.sh"

# Deploy one service (build + deploy + compose)
deploy_service() {
    svc="$1"; remote_base="$2"
    folder=$(get_service_folder "$svc")
    svc_dir="$SOLUTIONS_DIR/$folder"
    dist_dir="$svc_dir/dist"

    vm=$(get_svc_prop "$svc" "vm")
    [ "$vm" = "local" ] && return 0
    [ "$vm" = "all" ] && return 0

    # Build first if dist/ doesn't exist
    if [ ! -d "$dist_dir" ]; then
        build_service "$svc" || return 1
    fi

    if [ ! -d "$dist_dir" ]; then
        log "SKIP $svc (no dist/ after build)"
        return 0
    fi

    remote_path="$remote_base/$svc"
    log "Deploying $svc -> $vm:$remote_path"

    if [ "$DRY_RUN" = "1" ]; then
        log "[DRY-RUN] Would sync $dist_dir/ to $vm:$remote_path/"
        return 0
    fi

    # Create remote dir
    ssh_cmd "$vm" "sudo mkdir -p $remote_path && sudo chown \$(whoami):\$(whoami) $remote_path"

    # Sync dist/ to VM
    deploy_to_vm "$vm" "$dist_dir/" "$remote_path/"
    log "Deployed $svc to $vm:$remote_path/"
}

# Ship (build + deploy) one or all services
cmd_ship() {
    service="$1"
    remote_base=$(jq -r '.remote_base' "$CONFIG_FILE")

    if [ -n "$service" ]; then
        deploy_service "$service" "$remote_base"
    else
        log "Deploying all services..."
        get_all_services | while read -r svc; do
            deploy_service "$svc" "$remote_base" || true
        done
    fi
}

cmd_ship "$@"
