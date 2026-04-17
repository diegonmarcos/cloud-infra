# Step: Run containers on VM via docker compose (standard or custom)
# Sourced by cloud-ship-container-engine.sh — do not execute directly

step_compose() {
    CURRENT_STEP="compose"
    [ -z "$DEPLOY_HOST" ] && { log "No deploy.host -- skipping compose"; return 0; }
    [ -z "$DEPLOY_PATH" ] && { log "ERROR: deploy.remote_path not set in build.json"; return 1; }

    # Ensure Docker daemon is running
    if ! ssh $SSH_OPTS "$DEPLOY_HOST" "docker info >/dev/null 2>&1"; then
        log_warn "Docker not running on $DEPLOY_HOST — starting"
        ssh $SSH_OPTS "$DEPLOY_HOST" "sudo systemctl start docker" 2>/dev/null || true
        sleep 5
        if ! ssh $SSH_OPTS "$DEPLOY_HOST" "docker info >/dev/null 2>&1"; then
            log_error "Docker failed to start on $DEPLOY_HOST"
            return 1
        fi
    fi

    # Pre-hook (runs on VM before containers start)
    if [ -n "$COMPOSE_PRE_HOOK" ]; then
        if ssh $SSH_OPTS "$DEPLOY_HOST" "grep -q 'entrypoint.*$COMPOSE_PRE_HOOK' $DEPLOY_PATH/docker-compose.yml 2>/dev/null"; then
            log "Skipping pre_hook '$COMPOSE_PRE_HOOK' — container entrypoint"
        else
            log "Running pre-hook: $COMPOSE_PRE_HOOK"
            ssh $SSH_OPTS "$DEPLOY_HOST" "cd $DEPLOY_PATH && chmod +x $COMPOSE_PRE_HOOK && ./$COMPOSE_PRE_HOOK"
        fi
    fi

    # Determine compose up flags: --build --pull always if compose_flags includes --build,
    # otherwise pull from registry and --no-build
    COMPOSE_UP_FLAGS="--no-build --force-recreate"
    COMPOSE_PULL_FIRST="true"
    if echo "$COMPOSE_FLAGS" | grep -q -- '--build'; then
        COMPOSE_UP_FLAGS="--build --pull always --force-recreate"
        COMPOSE_PULL_FIRST="false"
    fi

    if [ "$COMPOSE_CUSTOM" = "true" ]; then
        # ── Custom compose script: self-contained, used by both ship + container-init ──
        SCRIPT_NAME="build-step-compose-custom.sh"
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
ENV_FILE_FLAG=""
[ -f .secrets ] && ENV_FILE_FLAG="--env-file .secrets"
COMPOSE_HEADER
            [ "$COMPOSE_PULL_FIRST" = "true" ] && echo 'docker compose $ENV_FILE_FLAG pull --quiet 2>/dev/null || true'
            echo 'docker compose $ENV_FILE_FLAG down --remove-orphans 2>/dev/null || true'
            echo "docker compose \$ENV_FILE_FLAG up -d $COMPOSE_UP_FLAGS"
        } > "$DIST_DIR/$SCRIPT_NAME"
        chmod +x "$DIST_DIR/$SCRIPT_NAME"

        log "Deploying + running $SCRIPT_NAME on $DEPLOY_HOST"
        rsync -az "$DIST_DIR/$SCRIPT_NAME" "$DEPLOY_HOST:$DEPLOY_PATH/$SCRIPT_NAME"
        ssh $SSH_OPTS "$DEPLOY_HOST" "cd $DEPLOY_PATH && sh $SCRIPT_NAME"
    else
        # ── Standard: direct docker compose up ──
        ENV_FILE_FLAG="\$([ -f .secrets ] && echo '--env-file .secrets')"
        log "Running docker compose up on $DEPLOY_HOST:$DEPLOY_PATH"
        if [ "$COMPOSE_PULL_FIRST" = "true" ]; then
            ssh $SSH_OPTS "$DEPLOY_HOST" "cd $DEPLOY_PATH && docker compose \$ENV_FILE_FLAG pull --quiet && docker compose \$ENV_FILE_FLAG down --remove-orphans 2>/dev/null; docker compose \$ENV_FILE_FLAG up -d $COMPOSE_UP_FLAGS"
        else
            ssh $SSH_OPTS "$DEPLOY_HOST" "cd $DEPLOY_PATH && docker compose \$ENV_FILE_FLAG down --remove-orphans 2>/dev/null; docker compose \$ENV_FILE_FLAG up -d $COMPOSE_UP_FLAGS"
        fi
    fi

    # Post-hook
    if [ -n "$COMPOSE_POST_HOOK" ]; then
        log "Running post-hook: $COMPOSE_POST_HOOK"
        ssh $SSH_OPTS "$DEPLOY_HOST" "cd $DEPLOY_PATH && chmod +x $COMPOSE_POST_HOOK && ./$COMPOSE_POST_HOOK"
    fi

    # Verify
    log "Verifying containers are running..."
    sleep 3
    ssh $SSH_OPTS "$DEPLOY_HOST" "docker ps --filter 'name=$(basename $DEPLOY_PATH)' --format '{{.Names}} {{.Status}}'" 2>/dev/null | while read -r line; do log "  $line"; done
    log "Done."
}
