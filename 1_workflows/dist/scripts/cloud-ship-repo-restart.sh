#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_workflows/src/scripts/cloud-ship-repo-restart.sh
# ║   Engine : 1_workflows/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

set -e
CLOUD_ROOT="${CLOUD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
. "$CLOUD_ROOT/1_workflows/src/scripts/cloud-ship-lib.sh"

# Restart service on VM
cmd_restart() {
    service="$1"
    [ -z "$service" ] && { log_error "Service name required"; exit 1; }
    vm=$(get_svc_prop "$service" "vm")
    remote_base=$(jq -r '.remote_base' "$CONFIG_FILE")
    log "Restarting $service on $vm..."
    ssh_cmd "$vm" "cd $remote_base/$service && docker compose down && docker compose \$([ -f .secrets ] && echo '--env-file .secrets') up -d"
    log "Restarted $service"
}

cmd_restart "$@"
