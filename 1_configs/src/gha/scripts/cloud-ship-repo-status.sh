#!/bin/sh
set -e
CLOUD_ROOT="${CLOUD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
. "$CLOUD_ROOT/1_configs/src/gha/scripts/cloud-ship-lib.sh"

# Docker status on VM
cmd_status() {
    vm_name="$1"
    [ -z "$vm_name" ] && { log_error "VM name required"; exit 1; }
    log "Docker status on $vm_name:"
    ssh_cmd "$vm_name" "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
}

cmd_status "$@"
