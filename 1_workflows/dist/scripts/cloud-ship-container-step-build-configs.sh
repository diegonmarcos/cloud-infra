# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_workflows/src/scripts/cloud-ship-container-step-build-configs.sh
# ║   Engine : 1_workflows/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Step: Push configs image to GHCR (dist/ -> busybox wrapper -> GHCR)
# Sourced by cloud-ship-container-engine.sh — do not execute directly

step_configs_push() {
    CURRENT_STEP="configs-push"
    [ ! -d "$DIST_DIR" ] && { log "No dist/ — skipping configs push"; return 0; }
    [ ! -f "$COMPOSE_FILE" ] && { log "No compose file ($COMPOSE_FILE) — skipping configs push"; return 0; }

    CONFIGS_IMAGE="${DOCKER_REGISTRY:-ghcr.io/diegonmarcos}/${SERVICE_NAME}-configs:latest"

    # Skip if dist/ unchanged since last configs push
    CONFIGS_HASH=$(find "$DIST_DIR" -type f ! -name 'Dockerfile.configs' ! -name '.configs-hash' -exec sha256sum {} \; 2>/dev/null | sort | sha256sum | cut -c1-16)
    OLD_CONFIGS_HASH=$(cat "$SERVICE_DIR/.configs-hash" 2>/dev/null || echo "")
    if [ "$CONFIGS_HASH" = "$OLD_CONFIGS_HASH" ] && [ -n "$CONFIGS_HASH" ]; then
        log "Configs unchanged — skipping push ($CONFIGS_HASH)"
        return 0
    fi

    # GHCR login
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        echo "$GITHUB_TOKEN" | docker login ghcr.io -u "$GITHUB_ACTOR" --password-stdin 2>/dev/null
    elif command -v gh >/dev/null 2>&1; then
        gh auth token 2>/dev/null | docker login ghcr.io -u "$(gh api user --jq .login 2>/dev/null)" --password-stdin 2>/dev/null
    else
        log_warn "No GHCR credentials — skipping configs push"
        return 0
    fi

    # Generate Dockerfile: busybox + all dist/ files EXCEPT secrets → /configs/
    # Backup existing .dockerignore, replace with secrets-excluding one
    [ -f "$DIST_DIR/.dockerignore" ] && cp "$DIST_DIR/.dockerignore" "$DIST_DIR/.dockerignore.bak"
    cat > "$DIST_DIR/.dockerignore" <<'DEOF'
.secrets
.secrets.d/
*.key
*.pem
*.age
Dockerfile.configs
.dockerignore.bak
.configs-hash
DEOF
    cat > "$DIST_DIR/Dockerfile.configs" <<'DEOF'
FROM busybox:latest
COPY . /configs/
CMD ["sh", "-c", "cp -r /configs/. /out/ && echo '[configs] extracted to /out'"]
DEOF

    log "Building configs image: $CONFIGS_IMAGE"
    docker build -q -t "$CONFIGS_IMAGE" -f "$DIST_DIR/Dockerfile.configs" "$DIST_DIR" || {
        log_warn "Configs image build failed (non-fatal)"
        return 0
    }
    docker push "$CONFIGS_IMAGE" 2>&1 | tail -3
    # Restore original .dockerignore
    rm -f "$DIST_DIR/Dockerfile.configs"
    if [ -f "$DIST_DIR/.dockerignore.bak" ]; then
        mv "$DIST_DIR/.dockerignore.bak" "$DIST_DIR/.dockerignore"
    else
        rm -f "$DIST_DIR/.dockerignore"
    fi
    echo "$CONFIGS_HASH" > "$SERVICE_DIR/.configs-hash"
    log "Pushed configs image: $CONFIGS_IMAGE ($CONFIGS_HASH) — secrets EXCLUDED"
}
