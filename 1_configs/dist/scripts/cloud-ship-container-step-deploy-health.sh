# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/deploy/scripts/cloud-ship-container-step-deploy-health.sh
# ║   Engine : 1_configs/src/deploy/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Step: Post-deploy health check — waits for all containers to be healthy
# Sourced by cloud-ship-container-engine.sh

step_health() {
    CURRENT_STEP="health"
    [ -z "$DEPLOY_HOST" ] && { log "No deploy.host -- skipping health"; return 0; }
    [ -z "$DEPLOY_PATH" ] && { log "ERROR: deploy.remote_path not set in build.json"; return 1; }

    local timeout="${HEALTH_TIMEOUT:-120}"
    local interval="${HEALTH_INTERVAL:-10}"
    local elapsed=0

    # Compose file resolution — same as step_compose. Without -f the v2 layout
    # (compose at compose/docker-compose.yml, not project root) makes
    # `docker compose ps` find NO compose file → empty listing → false "No
    # containers found". bash -c because the oci-apps login shell is fish.
    local cf="-f $REMOTE_COMPOSE_REL --project-directory ."

    log "Waiting for containers to be healthy (timeout: ${timeout}s)..."

    while [ "$elapsed" -lt "$timeout" ]; do
        # Get all container statuses from compose project
        local statuses
        statuses=$(ssh_with_retry "$DEPLOY_HOST" "bash -c 'cd \"$DEPLOY_PATH\" && docker compose $cf ps --format \"{{.Name}}|{{.State}}|{{.Health}}\" 2>/dev/null'" || true)

        if [ -z "$statuses" ]; then
            # Transient during recreate — keep waiting rather than hard-fail.
            log "No containers listed yet (${elapsed}s) — waiting"
            sleep "$interval"
            elapsed=$((elapsed + interval))
            continue
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
    ssh_with_retry "$DEPLOY_HOST" "bash -c 'cd \"$DEPLOY_PATH\" && docker compose $cf ps'" 2>/dev/null | while read -r l; do log "  $l"; done
    return 1
}
