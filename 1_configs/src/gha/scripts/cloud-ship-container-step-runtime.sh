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

# retire) FULL decommission in one shot: (1) containers DOWN on the VM,
# (2) back up the service's named volumes to a tarball on the VM, then PURGE
# them — fail-safe: the purge only runs if a non-empty backup exists, so a
# backup failure leaves the data intact, (3) git-mv the whole folder into
# a_solutions/z_archive/ (1_configs stops scanning it), (4) commit + push
# (the pre-commit hook regenerates derived config, dropping the service).
step_retire() {
    CURRENT_STEP="retire"
    log "═══ Retiring $SERVICE_NAME — FULL decommission ═══"

    # 1) Containers down (keep volumes momentarily for the backup).
    step_down

    # 2) Back up + purge named volumes (only on a real VM deploy).
    if [ -n "$DEPLOY_HOST" ] && [ -n "$DEPLOY_PATH" ]; then
        _bk="$DEPLOY_PATH/retired-volume-backup"
        # Volumes are labelled with their compose project (default = dir basename,
        # lowercased). Enumerate by label so we never guess individual names.
        _proj="$(basename "$DEPLOY_PATH" | tr '[:upper:]' '[:lower:]')"
        _vols="$(ssh_with_retry "$DEPLOY_HOST" "bash -c 'docker volume ls -q --filter label=com.docker.compose.project=$_proj 2>/dev/null'" 2>/dev/null || true)"
        if [ -n "$_vols" ]; then
            log "Backing up volumes → $_bk : $(echo $_vols | tr '\n' ' ')"
            for _v in $_vols; do
                ssh_with_retry "$DEPLOY_HOST" "bash -c 'mkdir -p \"$_bk\" && docker run --rm -v \"$_v\":/vol:ro -v \"$_bk\":/out alpine tar czf \"/out/$_v.tgz\" -C /vol . 2>/dev/null'" || log_warn "backup of $_v failed"
            done
            if ssh_with_retry "$DEPLOY_HOST" "bash -c 'ls \"$_bk\"/*.tgz >/dev/null 2>&1'"; then
                log "Backup verified → PURGING volumes (compose down --volumes)"
                _compose_remote "down --volumes --remove-orphans"
            else
                log_warn "No backup produced — SKIPPING volume purge (data kept). Purge manually after backup."
            fi
        else
            log "No compose-labelled volumes for project '$_proj' — nothing to purge"
        fi
    fi

    # 3) Archive the folder. cd to the PARENT first so the git-mv doesn't delete
    #    our CWD (moving a child dir is safe; moving CWD kills the shell).
    _sol_root="$(dirname "$SERVICE_DIR")"
    _svc_name="$(basename "$SERVICE_DIR")"
    if [ "$(basename "$_sol_root")" = "z_archive" ]; then
        log "Already under z_archive — VM purge done, nothing to move"; return 0
    fi
    _dest="$_sol_root/z_archive/$_svc_name"
    if [ -e "$_dest" ]; then log_error "$_dest already exists — refusing to overwrite"; return 1; fi
    cd "$_sol_root" || { log_error "cannot cd to $_sol_root"; return 1; }
    mkdir -p z_archive
    if git mv "$_svc_name" "z_archive/$_svc_name" 2>/dev/null; then
        log "Archived $_svc_name → z_archive/ (git mv)"
    else
        mv "$_svc_name" "z_archive/$_svc_name" && git add -A "z_archive/$_svc_name" "$_svc_name" 2>/dev/null || true
        log "Archived $_svc_name → z_archive/ (moved + staged)"
    fi

    # 4) Commit + push (rebase-retry once if the remote moved).
    if git diff --cached --quiet; then
        log "Nothing staged — skipping commit"
    else
        git commit -q -m "chore(retire): decommission $_svc_name → z_archive (containers + volumes purged; backup on $DEPLOY_HOST)"
        if git push origin HEAD 2>/dev/null; then
            log "Committed + pushed ✓"
        elif git pull --rebase origin HEAD 2>/dev/null && git push origin HEAD 2>/dev/null; then
            log "Committed + pushed ✓ (after rebase)"
        else
            log_warn "Committed locally — 'git push' failed (remote moved); push manually."
        fi
    fi
    log "$SERVICE_NAME decommissioned. Volume backup: $DEPLOY_HOST:$_bk"
}
