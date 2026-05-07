# Step: Run containers on VM via docker compose (standard or custom)
# Sourced by cloud-ship-container-engine.sh — do not execute directly

step_compose() {
    CURRENT_STEP="compose"
    [ -z "$DEPLOY_HOST" ] && { log "No deploy.host -- skipping compose"; return 0; }
    [ -z "$DEPLOY_PATH" ] && { log "ERROR: deploy.remote_path not set in build.json"; return 1; }

    # Ensure Docker daemon is running
    if ! ssh_with_retry "$DEPLOY_HOST" "docker info >/dev/null 2>&1"; then
        log_warn "Docker not running on $DEPLOY_HOST — starting"
        ssh_with_retry "$DEPLOY_HOST" "sudo systemctl start docker" 2>/dev/null || true
        sleep 5
        if ! ssh_with_retry "$DEPLOY_HOST" "docker info >/dev/null 2>&1"; then
            log_error "Docker failed to start on $DEPLOY_HOST"
            return 1
        fi
    fi

    # Repair: /root/.docker/config.json may exist as a DIRECTORY due to a
    # historical `docker run -v /root/.docker/config.json:...` bind-mount
    # where the host path was missing — docker auto-creates such paths as
    # directories. Subsequent `sudo docker compose pull` then fails with
    # auth/manifest errors because /root/.docker/config.json can't be read
    # as a JSON file. Idempotent: no-op when the path is a regular file or
    # missing. Same fix applied to RUNNER_HOST in step_docker (line ~458).
    # Re-login follows so private GHCR pulls work.
    GHCR_TOKEN_FILE="${HOME}/git/vault/A0_keys/providers/github/api-key_opaque/token"
    if [ -f "$GHCR_TOKEN_FILE" ]; then
        GHCR_TOKEN_VAL="$(cat "$GHCR_TOKEN_FILE")"
        # Use bash -c explicitly: target VMs may use fish/zsh as login shell
        # (e.g. oci-apps's diego user runs fish), and fish does not support
        # bash if/then/fi syntax; this wrapper guarantees POSIX semantics.
        ssh_with_retry "$DEPLOY_HOST" 'bash -c '"'"'
            if sudo test -d /root/.docker/config.json; then
                echo "[deploy-compose] /root/.docker/config.json is a DIRECTORY — repairing"
                sudo rm -rf /root/.docker/config.json
            fi
            sudo mkdir -p /root/.docker
        '"'" 2>&1 | while IFS= read -r line; do log "$line"; done
        # Login as root so `sudo docker compose pull` can fetch private GHCR images
        ssh_with_retry "$DEPLOY_HOST" "echo '$GHCR_TOKEN_VAL' | sudo docker login ghcr.io -u diegonmarcos --password-stdin >/dev/null 2>&1" || \
            log_warn "GHCR login on $DEPLOY_HOST failed (non-fatal — public images still work)"
    fi

    # Pre-hook (runs on VM before containers start)
    if [ -n "$COMPOSE_PRE_HOOK" ]; then
        if ssh_with_retry "$DEPLOY_HOST" "grep -q 'entrypoint.*$COMPOSE_PRE_HOOK' $DEPLOY_PATH/$REMOTE_COMPOSE_REL 2>/dev/null"; then
            log "Skipping pre_hook '$COMPOSE_PRE_HOOK' — container entrypoint"
        else
            log "Running pre-hook: $COMPOSE_PRE_HOOK"
            ssh_with_retry "$DEPLOY_HOST" "cd $DEPLOY_PATH && chmod +x $COMPOSE_PRE_HOOK && ./$COMPOSE_PRE_HOOK"
        fi
    fi

    # Compose up policy: NEVER build on the deploy VM. All images are pre-built
    # by the engine and pushed to GHCR (step_docker). VMs only PULL — they never
    # rebuild. This keeps 1GB e2-micro VMs alive (compose `build` would OOM)
    # and guarantees the running image matches what was tested in CI.
    #
    # `--build` in build.json's deploy.compose_flags is IGNORED at compose-up
    # time; the engine logs a warning so the legacy flag can be cleaned up.
    # --pull missing: pull images that aren't present locally (e.g. redis:7-bookworm
    # from Docker Hub on a fresh VM). Idempotent — only pulls when needed.
    # Was --pull never which broke first-time deployments and any service whose
    # compose references public images not pre-cached on the VM.
    COMPOSE_UP_FLAGS="--no-build --pull missing --force-recreate"
    COMPOSE_PULL_FIRST="true"
    if echo "$COMPOSE_FLAGS" | grep -q -- '--build'; then
        log_warn "deploy.compose_flags contains --build but VM rebuilds are disabled — using --no-build (engine pushes pre-built images to GHCR)"
    fi

    if [ "$COMPOSE_CUSTOM" = "true" ]; then
        # ── Custom compose script: self-contained, used by both ship + container-init ──
        # Generated in a tmpdir (ship transient — never pollutes dist/ or git working tree).
        SCRIPT_NAME="build-step-compose-custom.sh"
        TMP_SCRIPT="$(mktemp -t compose-custom.XXXXXX.sh)"
        trap 'rm -f "$TMP_SCRIPT"' EXIT
        log "Generating $SCRIPT_NAME (flags: $COMPOSE_UP_FLAGS)"
        {
            cat <<'COMPOSE_HEADER'
#!/bin/sh
set -e
if ! docker info >/dev/null 2>&1; then
  echo "[compose-custom] Docker not running — starting..."
  sudo systemctl start docker 2>/dev/null || true
  sleep 5
  docker info >/dev/null 2>&1 || { echo "[compose-custom] ERROR: Docker failed to start" >&2; exit 1; }
fi
# v2 layout: secrets live at compose/.secrets (alongside docker-compose.yml).
# But --project-directory . forces docker-compose's env_file resolution to
# ./.secrets at project root. Symlink so env_file: [".secrets"] in the YAML
# AND --env-file CLI both resolve to the same file.
ENV_FILE_FLAG=""
if [ -f compose/.secrets ]; then
  [ -e .secrets ] || ln -sf compose/.secrets .secrets
  ENV_FILE_FLAG="--env-file .secrets"
elif [ -f .secrets ]; then
  ENV_FILE_FLAG="--env-file .secrets"
fi
COMPOSE_HEADER
            # v2: compose at compose/ subdir; force project-dir=CWD for env_file/volumes resolution
            echo "COMPOSE_FILE_FLAG='-f $REMOTE_COMPOSE_REL --project-directory .'"
            [ "$COMPOSE_PULL_FIRST" = "true" ] && echo 'docker compose $COMPOSE_FILE_FLAG $ENV_FILE_FLAG pull --quiet 2>/dev/null || true'
            echo 'docker compose $COMPOSE_FILE_FLAG $ENV_FILE_FLAG down --remove-orphans 2>/dev/null || true'
            echo "docker compose \$COMPOSE_FILE_FLAG \$ENV_FILE_FLAG up -d $COMPOSE_UP_FLAGS"
        } > "$TMP_SCRIPT"
        chmod +x "$TMP_SCRIPT"

        log "Deploying + running $SCRIPT_NAME on $DEPLOY_HOST"
        rsync -az "$TMP_SCRIPT" "$DEPLOY_HOST:$DEPLOY_PATH/$SCRIPT_NAME"
        ssh_with_retry "$DEPLOY_HOST" "cd $DEPLOY_PATH && sh $SCRIPT_NAME && rm -f $SCRIPT_NAME"
        rm -f "$TMP_SCRIPT"
        trap - EXIT
    else
        # ── Standard: direct docker compose up ──
        # v2 layout: prefer compose/.secrets; fall back to ./.secrets.
        ENV_FILE_FLAG="\$([ -f compose/.secrets ] && echo '--env-file compose/.secrets' || ([ -f .secrets ] && echo '--env-file .secrets'))"
        CF="-f $REMOTE_COMPOSE_REL --project-directory ."
        log "Running docker compose up on $DEPLOY_HOST:$DEPLOY_PATH (compose=$REMOTE_COMPOSE_REL)"
        if [ "$COMPOSE_PULL_FIRST" = "true" ]; then
            # Pull is tolerant: if GHCR auth missing or registry unreachable, fall
            # back to locally cached image. Same pattern as COMPOSE_CUSTOM branch.
            ssh_with_retry "$DEPLOY_HOST" "cd $DEPLOY_PATH && docker compose $CF \$ENV_FILE_FLAG pull --quiet 2>/dev/null || true; docker compose $CF \$ENV_FILE_FLAG down --remove-orphans 2>/dev/null; docker compose $CF \$ENV_FILE_FLAG up -d $COMPOSE_UP_FLAGS"
        else
            ssh_with_retry "$DEPLOY_HOST" "cd $DEPLOY_PATH && docker compose $CF \$ENV_FILE_FLAG down --remove-orphans 2>/dev/null; docker compose $CF \$ENV_FILE_FLAG up -d $COMPOSE_UP_FLAGS"
        fi
    fi

    # Post-hook
    if [ -n "$COMPOSE_POST_HOOK" ]; then
        log "Running post-hook: $COMPOSE_POST_HOOK"
        ssh_with_retry "$DEPLOY_HOST" "cd $DEPLOY_PATH && chmod +x $COMPOSE_POST_HOOK && ./$COMPOSE_POST_HOOK"
    fi

    # Verify
    log "Verifying containers are running..."
    sleep 3
    ssh_with_retry "$DEPLOY_HOST" "docker ps --filter 'name=$(basename $DEPLOY_PATH)' --format '{{.Names}} {{.Status}}'" 2>/dev/null | while read -r line; do log "  $line"; done
    log "Done."
}
