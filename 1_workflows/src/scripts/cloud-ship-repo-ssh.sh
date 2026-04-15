#!/bin/sh
set -e
CLOUD_ROOT="${CLOUD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
. "$CLOUD_ROOT/1_workflows/src/scripts/cloud-ship-lib.sh"

# SSH into VM
cmd_ssh() {
    vm_name="$1"
    [ -z "$vm_name" ] && { log_error "VM name required"; get_all_vms | sed 's/^/  /'; exit 1; }
    log "Connecting to $vm_name..."
    ssh_cmd "$vm_name"
}

cmd_ssh "$@"
