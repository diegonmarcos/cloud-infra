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

# retire) Decommission the service: bring its containers DOWN on the VM (named
# volumes PERSIST — data is never deleted here), then git-mv the whole service
# folder into a_solutions/z_archive/ so 2_configs no longer scans it. Leaves the
# move STAGED — review + commit + push to finalize. Volume/data purge is a
# separate, deliberate, out-of-band step (hook-guarded; back up first).
step_retire() {
    CURRENT_STEP="retire"
    log "═══ Retiring $SERVICE_NAME ═══"

    # 1) Containers down on the VM (volumes persist). No-op if deploy.host unset.
    step_down

    # 2) Archive the service folder in-repo: <sol_root>/<name> → <sol_root>/z_archive/<name>
    _sol_root="$(dirname "$SERVICE_DIR")"
    _svc_name="$(basename "$SERVICE_DIR")"
    if [ "$(basename "$_sol_root")" = "z_archive" ]; then
        log "Already under z_archive — nothing to move"; return 0
    fi
    _dest="$_sol_root/z_archive/$_svc_name"
    if [ -e "$_dest" ]; then
        log_error "$_dest already exists — refusing to overwrite"; return 1
    fi
    mkdir -p "$_sol_root/z_archive"
    if git -C "$_sol_root" mv "$_svc_name" "z_archive/$_svc_name" 2>/dev/null; then
        log "Archived $_svc_name → z_archive/ (git mv, staged)"
    else
        # Untracked leftovers (e.g. a fresh dist/) can block git mv — move the
        # tracked tree, then relocate the rest so the folder ends up whole.
        mv "$SERVICE_DIR" "$_dest"
        git -C "$_sol_root" add -A "z_archive/$_svc_name" "$_svc_name" 2>/dev/null || true
        log "Archived $_svc_name → z_archive/ (moved + staged)"
    fi
    log "NEXT: review, then commit + push to finalize the decommission."
    log "NOTE: named volumes on $DEPLOY_HOST persist — purge separately after backup."
}
