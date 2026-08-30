# Step: Post-deploy health check — waits for all containers to be healthy
# Sourced by cloud-ship-container-engine.sh

# Assert every PUBLISHED port actually accepts a connection on the host.
#
# Container health is not service health: on 2026-08-29 a stalwart deploy
# recreated stalwart_default, the container moved to a new bridge IP, and
# docker left 10 DNAT rules pointing at the OLD address on a bridge that no
# longer existed. Zero rules pointed at the live container. Every published
# port — JMAP, IMAP, SMTP, ManageSieve — refused connections while the
# container reported `healthy`, because its healthcheck curls 127.0.0.1 from
# *inside* the netns and never crosses the NAT that was broken. The deploy
# went green and the mail server was dark.
#
# ponytail: a TCP connect, not a protocol probe. Anything deeper needs
# per-service knowledge the engine does not have, and a refused connect is
# the failure mode NAT breakage actually produces.
# Re-point published-port DNAT at the containers' current addresses, by piping
# cloud-ship-container-sync-dnat.sh to the host. See that script for why.
# Non-fatal: it is a repair, and _assert_published_ports is the actual verdict.
_sync_published_port_dnat() {
    local cf="$1"
    # STEPS_DIR is where the engine sourced this file from (it resolves the
    # build.sh symlink first), so the helper sits beside us.
    local helper="${STEPS_DIR:-$(dirname "$0")}/cloud-ship-container-sync-dnat.sh"
    [ -f "$helper" ] || { log "  dnat: helper missing, skipping repair"; return 0; }

    local out
    out=$(ssh -o ConnectTimeout=15 -o BatchMode=yes "$DEPLOY_HOST" \
              "cd '$DEPLOY_PATH' && sudo bash -s -- '$cf'" < "$helper" 2>/dev/null || true)
    [ -z "$out" ] && return 0
    # Only surface real changes; a fully correct fleet prints "ok ..." per port.
    echo "$out" | grep -v '^ok ' | while read -r l; do
        [ -n "$l" ] && log "  dnat: $l"
    done
    return 0
}

_assert_published_ports() {
    local cf="$1"
    local probe
    probe='for c in $(docker compose '"$cf"' ps --format "{{.Name}}" 2>/dev/null); do
        docker port "$c" 2>/dev/null | while read -r line; do
            hp=${line##*-> }
            [ "$hp" = "$line" ] && continue
            port=${hp##*:}
            ip=${hp%:*}
            case "$ip" in 0.0.0.0|::|"[::]") ip=127.0.0.1 ;; esac
            ip=${ip#[}; ip=${ip%]}
            if ! timeout 5 bash -c "exec 3<>/dev/tcp/$ip/$port" 2>/dev/null; then
                echo "DEAD $c $ip:$port"
            fi
        done
    done'

    # Retry: "healthy" is the container's own healthcheck, which can pass
    # before the service has finished binding its listeners. The 2026-08-30
    # 08:30 stalwart deploy failed here 6s after `All containers healthy (0s)`
    # while every port was in fact fine minutes later -- a false negative that
    # failed a deploy whose activate step had already succeeded. Only a probe
    # that stays dead for the whole window is a real failure.
    local dead=""
    local waited=0
    local grace="${PORT_ASSERT_GRACE:-45}"
    while :; do
        dead=$(ssh_with_retry "$DEPLOY_HOST" "bash -c 'cd \"$DEPLOY_PATH\" && $probe'" 2>/dev/null || true)
        [ -z "$dead" ] && return 0
        [ "$waited" -ge "$grace" ] && break
        sleep 5
        waited=$((waited + 5))
    done

    log "FAIL: ports still refusing after ${grace}s of healthy containers:"
    echo "$dead" | while read -r l; do log "  $l"; done
    log "  (typically orphaned docker DNAT rules after a network recreate --"
    log "   compare 'iptables -t nat -S DOCKER' against the live container IP)"
    return 1
}

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
            # Repair before asserting: on "iptables": false hosts the compose up
            # that just ran is itself what broke the published-port mapping, so
            # asserting first would only report a breakage we can fix here.
            _sync_published_port_dnat "$cf"
            _assert_published_ports "$cf" || return 1
            log "Published ports answering"
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
