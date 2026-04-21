# Step: Lifecycle commands — runs pre/post actions defined in build.json
# Sourced by cloud-ship-container-engine.sh

run_lifecycle() {
    COMMAND="$1"
    ACTIONS="$(get_lifecycle "$COMMAND")"

    if [ -z "$ACTIONS" ]; then
        log "No lifecycle.$COMMAND defined in build.json"
        return 1
    fi

    log "Running lifecycle: $COMMAND"
    echo "$ACTIONS" | while IFS= read -r action_json; do
        [ -z "$action_json" ] && continue

        ACTION="$(echo "$action_json" | node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(0,'utf8')).action||'')" 2>/dev/null || echo "$action_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('action',''),end='')")"
        VM="$(echo "$action_json" | node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(0,'utf8')).vm||'')" 2>/dev/null || echo "$action_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('vm',''),end='')")"
        CONTAINER="$(echo "$action_json" | node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(0,'utf8')).container||'')" 2>/dev/null || echo "$action_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('container',''),end='')")"
        COMPOSE_PATH="$(echo "$action_json" | node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(0,'utf8')).path||'')" 2>/dev/null || echo "$action_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('path',''),end='')")"
        SCRIPT="$(echo "$action_json" | node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(0,'utf8')).script||'')" 2>/dev/null || echo "$action_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('script',''),end='')")"

        : "${VM:=$DEPLOY_HOST}"

        case "$ACTION" in
            compose_stop)
                log "  Stopping compose at $VM:$COMPOSE_PATH"
                ssh -n $SSH_OPTS "$VM" "docker compose -f $COMPOSE_PATH/docker-compose.yml stop" || true
                ;;
            compose_start)
                log "  Starting compose at $VM:$COMPOSE_PATH"
                ssh -n $SSH_OPTS "$VM" "docker compose -f $COMPOSE_PATH/docker-compose.yml start"
                ;;
            compose_down)
                # Tear down the stack — removes containers + networks but keeps
                # named volumes (data survives for revert). Use compose_down_v
                # for destructive removal of volumes.
                log "  Tearing down compose at $VM:$COMPOSE_PATH"
                ssh -n $SSH_OPTS "$VM" "docker compose -f $COMPOSE_PATH/docker-compose.yml down --remove-orphans" || true
                ;;
            compose_down_v)
                log "  Tearing down compose (WITH VOLUMES) at $VM:$COMPOSE_PATH"
                ssh -n $SSH_OPTS "$VM" "docker compose -f $COMPOSE_PATH/docker-compose.yml down --remove-orphans --volumes" || true
                ;;
            volume_remove)
                # Remove a named Docker volume. Destructive — use when the
                # service is being decommissioned and its data is no longer
                # needed. Uses `volume` field from lifecycle entry.
                VOLUME="$(echo "$action_json" | node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(0,'utf8')).volume||'')" 2>/dev/null || echo "$action_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('volume',''),end='')")"
                [ -z "$VOLUME" ] && { log "  volume_remove: no 'volume' field"; continue; }
                log "  Removing volume $VOLUME on $VM"
                ssh -n $SSH_OPTS "$VM" "docker volume rm '$VOLUME'" || true
                ;;
            path_remove)
                # Remove a filesystem path on the VM host. Destructive. Uses
                # `path` field from lifecycle entry. Safety: refuses empty,
                # '/', or any path not under /opt or /srv. Uses sudo because
                # /opt/containers/* is root-owned on the VMs.
                case "$COMPOSE_PATH" in
                    ""|"/") log "  path_remove: refusing unsafe path '$COMPOSE_PATH'"; continue ;;
                    /opt/*|/srv/*|/tmp/*) : ;;
                    *) log "  path_remove: refusing path outside /opt|/srv|/tmp: '$COMPOSE_PATH'"; continue ;;
                esac
                log "  Removing $VM:$COMPOSE_PATH (sudo)"
                ssh -n $SSH_OPTS "$VM" "sudo rm -rf -- '$COMPOSE_PATH'" || true
                ;;
            exec)
                log "  Exec in $CONTAINER on $VM: $SCRIPT"
                ssh -n $SSH_OPTS "$VM" "docker exec $CONTAINER $SCRIPT" || true
                ;;
            stats)
                ssh -n $SSH_OPTS "$VM" "free -h && echo '---' && docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}'"
                ;;
            ssh_run)
                # Run a script on the VM host (outside any container)
                # $SCRIPT is an absolute path on the VM (must be deployed there first)
                log "  ssh_run on $VM: $SCRIPT"
                ssh -n $SSH_OPTS "$VM" "sh $SCRIPT"
                ;;
        esac
    done

    log "Lifecycle $COMMAND complete"
}
