# Step: Post-deploy health check — waits for all containers to be healthy
# Sourced by cloud-ship-container-engine.sh

step_health() {
    CURRENT_STEP="health"
    [ -z "$DEPLOY_HOST" ] && { log "No deploy.host -- skipping health"; return 0; }
    [ -z "$DEPLOY_PATH" ] && { log "ERROR: deploy.remote_path not set in build.json"; return 1; }

    local timeout="${HEALTH_TIMEOUT:-120}"
    local interval="${HEALTH_INTERVAL:-10}"
    local elapsed=0

    log "Waiting for containers to be healthy (timeout: ${timeout}s)..."

    while [ "$elapsed" -lt "$timeout" ]; do
        # Get all container statuses from compose project
        local statuses
        statuses=$(ssh_with_retry "$DEPLOY_HOST" "cd $DEPLOY_PATH && docker compose ps --format '{{.Name}}|{{.State}}|{{.Health}}' 2>/dev/null" || true)

        if [ -z "$statuses" ]; then
            log "WARNING: No containers found"
            return 1
        fi

        local all_ok=true
        local has_health=false

        while IFS='|' read -r cname cstate chealth; do
            [ -z "$cname" ] && continue

            # Crash loop detection: "restarting" state
            if echo "$cstate" | grep -qi "restarting"; then
                log "FAIL: $cname is crash-looping"
                ssh_with_retry "$DEPLOY_HOST" "docker logs --tail 15 $cname 2>&1" | while read -r l; do log "  $l"; done
                return 1
            fi

            # Container with healthcheck defined
            if [ -n "$chealth" ] && [ "$chealth" != "" ]; then
                has_health=true
                if echo "$chealth" | grep -qi "healthy"; then
                    : # healthy, good
                elif echo "$chealth" | grep -qi "unhealthy"; then
                    log "FAIL: $cname is unhealthy"
                    ssh_with_retry "$DEPLOY_HOST" "docker logs --tail 15 $cname 2>&1" | while read -r l; do log "  $l"; done
                    return 1
                else
                    all_ok=false  # still starting
                fi
            else
                # No healthcheck — just verify running
                if ! echo "$cstate" | grep -qi "running"; then
                    if echo "$cstate" | grep -qi "exited"; then
                        : # one-shot containers (init, migrations) are OK
                    else
                        all_ok=false
                    fi
                fi
            fi
        done <<EOF
$statuses
EOF

        if [ "$all_ok" = "true" ]; then
            log "All containers healthy (${elapsed}s)"
            return 0
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    # Timeout — show final state
    log "TIMEOUT: Not all containers healthy after ${timeout}s"
    ssh_with_retry "$DEPLOY_HOST" "cd $DEPLOY_PATH && docker compose ps" 2>/dev/null | while read -r l; do log "  $l"; done
    return 1
}
