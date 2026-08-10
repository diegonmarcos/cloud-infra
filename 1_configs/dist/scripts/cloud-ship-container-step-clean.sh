# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/deploy/scripts/cloud-ship-container-step-clean.sh
# ║   Engine : 1_configs/src/deploy/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Step: Clean remote — remove non-manifest files from deploy path
# For intentional full cleanup of runtime state (DBs, caches, logs).
# Shows a dry-run first, requires explicit --force to actually delete.
# Sourced by cloud-ship-container-engine.sh

step_clean_remote() {
    FORCE_FLAG="$1"
    [ -z "$DEPLOY_HOST" ] && { log "No deploy.host -- nothing to clean"; return 0; }
    [ -z "$DEPLOY_PATH" ] && { log "ERROR: deploy.remote_path not set"; return 1; }

    MANIFEST_FILE=".deploy-manifest"
    MANIFEST=$(ssh $SSH_OPTS "$DEPLOY_HOST" "cat '$DEPLOY_PATH/$MANIFEST_FILE' 2>/dev/null" || true)

    if [ -z "$MANIFEST" ]; then
        log "No deploy manifest found — cannot determine engine-owned files"
        log "Run 'build.sh ship' first to establish a manifest"
        return 1
    fi

    # List all files on remote, find those NOT in manifest
    ALL_REMOTE=$(ssh $SSH_OPTS "$DEPLOY_HOST" "cd '$DEPLOY_PATH' && find . -type f | sort")
    MANIFEST_TMP=$(mktemp)
    REMOTE_TMP=$(mktemp)
    KNOWN_TMP=$(mktemp)
    echo "$ALL_REMOTE" > "$REMOTE_TMP"
    # Known files = manifest + the manifest file itself
    { echo "$MANIFEST"; echo "./$MANIFEST_FILE"; } | sort -u > "$KNOWN_TMP"

    # comm -23: lines only in remote (not in known) = extra files
    EXTRA_FILES=$(comm -23 "$REMOTE_TMP" "$KNOWN_TMP")
    rm -f "$MANIFEST_TMP" "$REMOTE_TMP" "$KNOWN_TMP"

    if [ -z "$EXTRA_FILES" ]; then
        log "No non-manifest files found — remote is clean"
        return 0
    fi

    log "Non-manifest files on $DEPLOY_HOST:$DEPLOY_PATH:"
    echo "$EXTRA_FILES" | while IFS= read -r f; do
        [ -z "$f" ] && continue
        echo "  $f"
    done

    if [ "$FORCE_FLAG" = "--force" ]; then
        log "Removing non-manifest files (--force)"
        echo "$EXTRA_FILES" | while IFS= read -r f; do
            [ -z "$f" ] && continue
            ssh $SSH_OPTS "$DEPLOY_HOST" "rm -f '$DEPLOY_PATH/$f'"
        done
        log "Remote cleaned"
    else
        log "Dry run — add --force to actually delete"
    fi
}
