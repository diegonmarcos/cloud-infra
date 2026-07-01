# Step: runtime verbs — pull / down / restart (image + lifecycle plane)
# Sourced by cloud-ship-container-engine.sh — do not execute directly.
#
# Thin, single-responsibility VM-side compose ops that complete the verb
# surface (the C/Pull, down, and II/Restart of the k8s-style model). They
# mirror step_compose's remote invocation exactly: compose file resolved to
# $REMOTE_COMPOSE_REL, run from $DEPLOY_PATH, wrapped in `bash -c` because the
# oci-apps login shell is fish (which mangles POSIX `$(...)` / redirections).
# VMs NEVER build — same doctrine as step_compose.

# Shared helper: run a compose subcommand on the VM.
_compose_remote() {
    _sub="$1"
    [ -z "$DEPLOY_HOST" ] && { log "No deploy.host — VM-only op, skipping"; return 0; }
    [ -z "$DEPLOY_PATH" ] && { log "ERROR: deploy.remote_path not set in build.json"; return 1; }
    _cf="-f $REMOTE_COMPOSE_REL --project-directory ."
    ssh_with_retry "$DEPLOY_HOST" "bash -c 'cd \"$DEPLOY_PATH\" && docker compose $_cf $_sub'"
}

# C) Pull image(s) from GHCR onto the VM — no restart. Registry→VM only.
step_pull() {
    CURRENT_STEP="pull"
    log "Pulling images for $SERVICE_NAME on $DEPLOY_HOST"
    _compose_remote "pull"
}

# down) Stop + remove containers (named volumes persist). DESTRUCTIVE to running
# state — brings the service down until `up`/`compose`/`ship` restores it.
step_down() {
    CURRENT_STEP="down"
    log "Bringing $SERVICE_NAME DOWN on $DEPLOY_HOST"
    _compose_remote "down --remove-orphans"
}

# II) Restart in place — no pull, no recreate, no config change. Brief blip.
step_restart() {
    CURRENT_STEP="restart"
    log "Restarting $SERVICE_NAME on $DEPLOY_HOST"
    _compose_remote "restart"
}
