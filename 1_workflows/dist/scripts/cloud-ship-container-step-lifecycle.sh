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
                ssh $SSH_OPTS "$VM" "docker compose -f $COMPOSE_PATH/docker-compose.yml stop" || true
                ;;
            compose_start)
                log "  Starting compose at $VM:$COMPOSE_PATH"
                ssh $SSH_OPTS "$VM" "docker compose -f $COMPOSE_PATH/docker-compose.yml start"
                ;;
            exec)
                log "  Exec in $CONTAINER on $VM: $SCRIPT"
                ssh $SSH_OPTS "$VM" "docker exec $CONTAINER $SCRIPT" || true
                ;;
            stats)
                ssh $SSH_OPTS "$VM" "free -h && echo '---' && docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}'"
                ;;
            ssh_run)
                # Run a script on the VM host (outside any container)
                # $SCRIPT is an absolute path on the VM (must be deployed there first)
                log "  ssh_run on $VM: $SCRIPT"
                ssh $SSH_OPTS "$VM" "sh $SCRIPT"
                ;;
        esac
    done

    log "Lifecycle $COMMAND complete"
}
