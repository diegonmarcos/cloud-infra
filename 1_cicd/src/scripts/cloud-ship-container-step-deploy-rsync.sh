# Step: Deploy dist/ to VM via configs image (GHCR) + rsync fallback + manifest cleanup
# Sourced by cloud-ship-container-engine.sh — do not execute directly

step_deploy() {
    CURRENT_STEP="deploy"
    [ -z "$DEPLOY_HOST" ] && { log "No deploy.host -- skipping deploy"; return 0; }
    [ -z "$DEPLOY_PATH" ] && { log "ERROR: deploy.remote_path not set in build.json"; return 1; }
    [ ! -d "$DIST_DIR" ] && { log "No dist/ -- run build first"; return 1; }

    # ── Deploy: configs image (GHCR) + secrets (scp) — universal, all VMs ──
    CONFIGS_IMAGE="${DOCKER_REGISTRY:-ghcr.io/diegonmarcos}/${SERVICE_NAME}-configs:latest"

    log "Deploying via configs image: $CONFIGS_IMAGE"
    # The configs image extracts with `cp -r /configs/. /out/` running as root
    # inside the container, so every file it lands in the bind mount is
    # root-owned. The chown that repairs that used to be the last link of an
    # &&-chain, which meant it only ran when the whole chain succeeded — and
    # the interesting case is precisely when it didn't. A pull or a half-done
    # extract left root-owned files behind, then the rsync fallback (which
    # runs as the ssh user, not root) hit them:
    #   rsync: failed to set times on ".../.src-hash": Operation not permitted
    #   rsync error: some files/attrs were not transferred (code 23)
    # and the service failed to deploy. Normalising ownership unconditionally
    # afterwards makes the fallback able to do its job, which is the entire
    # reason a fallback exists.
    ssh_with_retry "$DEPLOY_HOST" "sudo mkdir -p $DEPLOY_PATH && sudo chown \$(whoami):\$(whoami) $DEPLOY_PATH && \
        docker pull $CONFIGS_IMAGE && \
        docker run --rm -v $DEPLOY_PATH:/out $CONFIGS_IMAGE" && {
        _configs_ok=1
    } || {
        _configs_ok=0
    }
    ssh_with_retry "$DEPLOY_HOST" "sudo chown -R \$(whoami):\$(whoami) $DEPLOY_PATH" >/dev/null 2>&1 \
        || log_warn "could not normalise ownership of $DEPLOY_PATH — a root-owned leftover will fail rsync"

    if [ "$_configs_ok" = "1" ]; then
        log "Deployed configs to $DEPLOY_HOST:$DEPLOY_PATH (via configs image)"
    else
        log_warn "Configs image deploy failed — falling back to rsync"
        # Rsync fallback (only if configs image unavailable, e.g. first-ever ship)
        log "Deploying dist/ -> $DEPLOY_HOST:$DEPLOY_PATH (rsync fallback)"
        rsync_with_retry -az --compress-level=9 --checksum "$DIST_DIR/" "$DEPLOY_HOST:$DEPLOY_PATH/" 2>/dev/null || true
    fi

    # Secrets: ALWAYS via scp (never in GHCR image)
    if [ -f "$DIST_DIR/.secrets" ]; then
        scp $SSH_OPTS "$DIST_DIR/.secrets" "$DEPLOY_HOST:$DEPLOY_PATH/.secrets" 2>/dev/null && \
            log "Deployed .secrets via scp" || log_warn ".secrets scp failed"
    fi
    if [ -d "$DIST_DIR/.secrets.d" ]; then
        scp $SSH_OPTS -r "$DIST_DIR/.secrets.d" "$DEPLOY_HOST:$DEPLOY_PATH/.secrets.d" 2>/dev/null && \
            log "Deployed .secrets.d via scp" || log_warn ".secrets.d scp failed"
    fi

    log "Deployed to $DEPLOY_HOST:$DEPLOY_PATH"

    # Include binary + runtime Dockerfile for local image build on VM
    BINARY_PATH="/tmp/${SERVICE_NAME}-binary"
    RUNTIME_DF="$SRC_DIR/Dockerfile.runtime"
    if [ -f "$BINARY_PATH" ] && [ -f "$RUNTIME_DF" ]; then
        cp "$BINARY_PATH" "$DIST_DIR/$DOCKER_BINARY_NAME"
        cp "$RUNTIME_DF" "$DIST_DIR/Dockerfile.runtime"
        log "Included binary + Dockerfile.runtime in deploy payload"
    fi

    log "Deploying dist/ -> $DEPLOY_HOST:$DEPLOY_PATH"

    # Ensure remote dir exists
    ssh_with_retry "$DEPLOY_HOST" "sudo mkdir -p $DEPLOY_PATH && sudo chown \$(whoami):\$(whoami) $DEPLOY_PATH"

    MANIFEST_FILE=".deploy-manifest"

    # 1. Build list of files we're about to deploy (relative paths)
    NEW_MANIFEST=$(cd "$DIST_DIR" && find . -type f | sort)

    # 2. Read old manifest from remote (may be empty on first deploy)
    OLD_MANIFEST=$(ssh_with_retry "$DEPLOY_HOST" "cat '$DEPLOY_PATH/$MANIFEST_FILE' 2>/dev/null" || true)

    # 3. Build rsync exclude flags from build.json array
    RSYNC_EXCLUDES=""
    EXCLUDES="$(get_config_array deploy.excludes)"
    if [ -n "$EXCLUDES" ]; then
        RSYNC_EXCLUDES=$(echo "$EXCLUDES" | while IFS= read -r ex; do
            [ -n "$ex" ] && printf " --exclude '%s'" "$ex"
        done)
    fi

    # 3b. Clean specified subdirectories (deploy.clean_dirs) — ensures exact mirror
    CLEAN_DIRS="$(get_config_array deploy.clean_dirs)"
    if [ -n "$CLEAN_DIRS" ]; then
        echo "$CLEAN_DIRS" | while IFS= read -r d; do
            [ -z "$d" ] && continue
            log "  clean: $DEPLOY_PATH/$d/"
            ssh_with_retry "$DEPLOY_HOST" "rm -rf '$DEPLOY_PATH/$d/'"
        done
    fi

    # 4. Additive rsync (NO --delete) — adds/updates files, never removes
    if command -v rsync >/dev/null 2>&1; then
        eval rsync_with_retry -az --compress-level=9 --checksum --partial --inplace --exclude='docs/' $RSYNC_EXCLUDES '"$DIST_DIR/"' '"$DEPLOY_HOST:$DEPLOY_PATH/"'
    elif command -v rclone >/dev/null 2>&1; then
        rclone copy "$DIST_DIR/" ":sftp:$DEPLOY_PATH/" \
            --sftp-host="$(ssh -G "$DEPLOY_HOST" | grep '^hostname ' | awk '{print $2}')" \
            --sftp-user="$(ssh -G "$DEPLOY_HOST" | grep '^user ' | awk '{print $2}')" \
            --sftp-key-file="$(ssh -G "$DEPLOY_HOST" | grep '^identityfile ' | head -1 | awk '{print $2}')" \
            --transfers=4
    else
        log "ERROR: No rsync or rclone available"
        return 1
    fi

    # 5. Clean stale files: in old manifest but not in new
    if [ -n "$OLD_MANIFEST" ]; then
        STALE_COUNT=0
        # Write manifests to temp files for reliable comparison (avoids subshell issues)
        OLD_TMP=$(mktemp)
        NEW_TMP=$(mktemp)
        echo "$OLD_MANIFEST" | sort > "$OLD_TMP"
        echo "$NEW_MANIFEST" | sort > "$NEW_TMP"
        # comm -23: lines only in old (stale files)
        STALE_FILES=$(comm -23 "$OLD_TMP" "$NEW_TMP")
        rm -f "$OLD_TMP" "$NEW_TMP"
        if [ -n "$STALE_FILES" ]; then
            echo "$STALE_FILES" | while IFS= read -r f; do
                [ -z "$f" ] && continue
                log "  rm stale: $f"
                ssh_with_retry "$DEPLOY_HOST" "rm -f '$DEPLOY_PATH/$f'"
                STALE_COUNT=$((STALE_COUNT + 1))
            done
            log "Cleaned stale files from previous deploy"
        fi
    fi

    # 6. Save new manifest to remote
    echo "$NEW_MANIFEST" | ssh_with_retry "$DEPLOY_HOST" "cat > '$DEPLOY_PATH/$MANIFEST_FILE'"

    log "Deployed to $DEPLOY_HOST:$DEPLOY_PATH"
}
