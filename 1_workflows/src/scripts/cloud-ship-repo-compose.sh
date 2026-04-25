#!/bin/sh
set -e
CLOUD_ROOT="${CLOUD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
. "$CLOUD_ROOT/1_workflows/src/scripts/cloud-ship-lib.sh"

# Compose up on VM
cmd_compose() {
    service="$1"
    remote_base=$(jq -r '.remote_base' "$CONFIG_FILE")

    if [ -n "$service" ]; then
        vm=$(get_svc_prop "$service" "vm")
        remote_path="$remote_base/$service"
        log "docker compose pull + up on $vm:$remote_path"
        # Policy: images are always pre-built on GHCR — VMs only pull, never
        # build. --no-build prevents any compose `build:` block from
        # triggering a doomed cargo/npm/etc compile on a 1GB VM. --pull
        # always ensures we get the latest GHCR digest before bringing up.
        ssh_cmd "$vm" "cd $remote_path && docker compose down 2>/dev/null; docker compose \$([ -f .secrets ] && echo '--env-file .secrets') pull --quiet && docker compose \$([ -f .secrets ] && echo '--env-file .secrets') up -d --no-build --force-recreate"
    else
        log_error "Service name required for compose"
        exit 1
    fi
}

cmd_compose "$@"
