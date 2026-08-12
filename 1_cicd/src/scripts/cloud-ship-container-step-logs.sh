# Step: logs — tail container logs from the VM (the F/LOGS verb)
# Sourced by cloud-ship-container-engine.sh — do not execute directly.
#
# Usage (from engine dispatch):  build.sh logs [TAIL] [follow]
#   TAIL    number of trailing lines (default 100)
#   follow  literal word "follow" / "-f" → stream (Ctrl-C to stop)
#
# Read-only. Uses the compose project so multi-container services show
# interleaved, service-prefixed output — same as `kubectl logs deploy/...`.

step_logs() {
    CURRENT_STEP="logs"
    [ -z "$DEPLOY_HOST" ] && { log "No deploy.host — logs are VM-only"; return 0; }
    [ -z "$DEPLOY_PATH" ] && { log "ERROR: deploy.remote_path not set in build.json"; return 1; }

    _tail="${LOGS_TAIL:-100}"
    _follow=""
    case "${LOGS_FOLLOW:-}" in follow|-f|1|true) _follow="--follow" ;; esac

    # --project-directory . so compose resolves the same project as deploy.
    _cf="-f $REMOTE_COMPOSE_REL --project-directory ."
    log "Logs for $SERVICE_NAME @ $DEPLOY_HOST (tail=$_tail${_follow:+, following})"
    # bash -c: target VMs may run fish as login shell (oci-apps) which rejects
    # POSIX flag handling here — same guarantee pattern as step_compose.
    ssh_with_retry "$DEPLOY_HOST" \
        "bash -c 'cd \"$DEPLOY_PATH\" && docker compose $_cf logs --tail $_tail --no-color $_follow'"
}
