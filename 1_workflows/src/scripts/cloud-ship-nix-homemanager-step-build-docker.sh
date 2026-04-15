# Step: Docker package (nix build -> Docker context with closure)
# Sourced by cloud-ship-nix-homemanager-engine.sh — do not execute directly

step_docker_package() {
    [ -z "$HM_IMAGE" ] && { log "ERROR: hm.image not set in build.json"; return 1; }

    cd "$DIST_DIR"
    # Nix flakes in git repos only see tracked files
    git add "$DIST_DIR" 2>&1 | tee -a "$BUILD_LOG_FILE" || true
    log "Staged dist/ for nix ($(find "$DIST_DIR" -type f | wc -l) files)"

    NIX_RESULT_LINK2="$DIST_DIR/.hm-result"
    NIX_BUILD_CMD="nix build --out-link $NIX_RESULT_LINK2 --option eval-cache false .#homeConfigurations.\"$HM_CONFIG\".activationPackage"
    log "Flake: $DIST_DIR"
    log "Nix cmd: $NIX_BUILD_CMD"

    NIX_TMP=$(mktemp)
    set +e
    DEPS_FLAKE="$SERVICE_DIR/../../workflows/src/cloud-builder/src"
    if [ -d "$DEPS_FLAKE" ] && command -v nix >/dev/null 2>&1; then
        log "Using deps devShell from $DEPS_FLAKE"
        nix develop "$DEPS_FLAKE#" --command bash -c "cd '$DIST_DIR' && $NIX_BUILD_CMD" >"$NIX_TMP" 2>&1
        NIX_RC=$?
    else
        eval "$NIX_BUILD_CMD" >"$NIX_TMP" 2>&1
        NIX_RC=$?
    fi
    set -e
    NIX_OUT=$(cat "$NIX_TMP")
    cat "$NIX_TMP" >> "$BUILD_LOG_FILE"
    rm -f "$NIX_TMP"

    if [ "$NIX_RC" -ne 0 ]; then
        log "ERROR: nix build failed (exit $NIX_RC)"
        log "Full nix output:"
        printf '%s\n' "$NIX_OUT"
        return 1
    fi

    RESULT=""
    if [ -L "$NIX_RESULT_LINK2" ]; then
        RESULT=$(readlink -f "$NIX_RESULT_LINK2")
        rm -f "$NIX_RESULT_LINK2"
    fi
    if [ -z "$RESULT" ] || [ ! -d "$RESULT" ]; then
        log "ERROR: nix build produced no valid store path"
        log "Full nix output:"
        printf '%s\n' "$NIX_OUT"
        return 1
    fi
    log "Closure built: $RESULT"

    # Collect runtime closure (only store paths referenced at runtime)
    log "Collecting runtime closure..."
    DOCKER_CTX="$DIST_DIR/docker-ctx"
    rm -rf "$DOCKER_CTX"
    mkdir -p "$DOCKER_CTX/nix-store"

    CLOSURE_PATHS=$(nix-store -qR "$RESULT")
    CLOSURE_COUNT=$(printf '%s\n' "$CLOSURE_PATHS" | wc -l)
    CLOSURE_SIZE=$(printf '%s\n' "$CLOSURE_PATHS" | xargs du -scm 2>/dev/null | tail -1 | cut -f1)
    log "Runtime closure: $CLOSURE_COUNT paths, ${CLOSURE_SIZE}MB"

    # Copy closure paths (preserve structure)
    printf '%s\n' "$CLOSURE_PATHS" | while read -r storepath; do
        cp -a "$storepath" "$DOCKER_CTX/nix-store/" 2>/dev/null || true
    done

    # Export nix closure for import on VM (register paths in nix DB)
    log "Exporting nix closure registration..."
    nix-store --export $(nix-store -qR "$RESULT") 2>/dev/null | gzip > "$DOCKER_CTX/nix-closure.nar.gz" || {
        log "WARN: nix-store --export failed"
        rm -f "$DOCKER_CTX/nix-closure.nar.gz"
    }
    if [ -f "$DOCKER_CTX/nix-closure.nar.gz" ]; then
        NAR_SIZE=$(du -sh "$DOCKER_CTX/nix-closure.nar.gz" | cut -f1)
        log "NAR export: $NAR_SIZE (compressed)"
    fi

    # Copy encrypted secrets if present
    [ -f "$SRC_DIR/secrets.yaml" ] && cp "$SRC_DIR/secrets.yaml" "$DOCKER_CTX/"

    # Generate activate.sh
    RESULT_BASENAME=$(basename "$RESULT")
    HM_USER="$(get_config hm.user)"
    cat > "$DOCKER_CTX/activate.sh" <<'ACTIVATE_EOF'
#!/bin/bash
set -euo pipefail
HOST="${HM_HOST_ROOT:-/host}"
HM_USER="${HM_USER:-ubuntu}"
HM_HOME="$HOST/home/$HM_USER"
ACTIVATION="$HOST$HM_ACTIVATION_PATH/activate"

log() { printf '[hm-activate] %s\n' "$1"; }

log "Copying nix store paths to host..."
cp -rn /nix/store/* "$HOST/nix/store/" 2>/dev/null || true

# Import nix closure into host's nix DB (so nix-build recognizes paths)
log "Importing nix closure into host DB..."
if [ -f "/hm/nix-closure.nar.gz" ]; then
    log "NAR file found ($(du -sh /hm/nix-closure.nar.gz | cut -f1))"
    # Decompress and import via chroot (uses host's nix-store binary)
    gunzip -c /hm/nix-closure.nar.gz | chroot "$HOST" /bin/bash -c "
        export PATH=/nix/var/nix/profiles/default/bin:\$PATH
        nix-store --import
    " 2>&1 | tail -5
    log "Nix closure imported"
else
    log "WARN: /hm/nix-closure.nar.gz not found — activation may fail"
    ls -la /hm/ 2>/dev/null
fi

# Decrypt secrets using host's age key
if [ -f "/hm/secrets.yaml" ]; then
    AGE_KEY="$HM_HOME/.config/sops/age/keys.txt"
    if [ -f "$AGE_KEY" ] && command -v sops >/dev/null 2>&1; then
        log "Decrypting secrets..."
        mkdir -p "$HM_HOME/.config/home-manager/.secrets.d"
        SOPS_AGE_KEY_FILE="$AGE_KEY" sops -d /hm/secrets.yaml > /tmp/.hm-secrets-raw
        # Extract KEY=VALUE pairs
        if command -v yq >/dev/null 2>&1; then
            : > "$HM_HOME/.config/home-manager/.secrets"
            for key in $(yq -r 'keys | .[] | select(. != "sops")' /tmp/.hm-secrets-raw); do
                val=$(yq -r ".[\"$key\"]" /tmp/.hm-secrets-raw)
                printf '%s=%s\n' "$key" "$val" >> "$HM_HOME/.config/home-manager/.secrets"
                printf '%s\n' "$val" > "$HM_HOME/.config/home-manager/.secrets.d/$key"
                chmod 600 "$HM_HOME/.config/home-manager/.secrets.d/$key"
            done
            log "Secrets decrypted ($(wc -l < "$HM_HOME/.config/home-manager/.secrets") keys)"
        fi
        rm -f /tmp/.hm-secrets-raw
    else
        log "WARN: No age key or sops — skipping secrets"
    fi
fi

# Create nix-build/nix-instantiate symlinks (HM activate needs them)
NIX_DIR="$HOST/nix/var/nix/profiles/default/bin"
for cmd in nix-build nix-instantiate nix-env nix-store nix-channel; do
    [ ! -e "$NIX_DIR/$cmd" ] && ln -sf nix "$NIX_DIR/$cmd" && log "Created $cmd symlink"
done

# Write activation path — ship-hm.sh runs activate natively via SSH
echo "$HM_ACTIVATION_PATH" > "$HOST/tmp/.hm-activation-path"
log "Container done — activation path: $HM_ACTIVATION_PATH"
ACTIVATE_EOF

    # Generate Dockerfile
    SECRETS_COPY=""
    [ -f "$DOCKER_CTX/secrets.yaml" ] && SECRETS_COPY="COPY secrets.yaml /hm/secrets.yaml"
    NAR_COPY=""
    [ -f "$DOCKER_CTX/nix-closure.nar.gz" ] && NAR_COPY="COPY nix-closure.nar.gz /hm/nix-closure.nar.gz"
    cat > "$DOCKER_CTX/Dockerfile" <<DOCKERFILE_EOF
FROM ghcr.io/diegonmarcos/user-dev-x86-deb-nix-hm:latest
USER root
LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
LABEL org.opencontainers.image.description="Home-Manager activation image for $SERVICE_NAME"
COPY nix-store/ /nix/store/
COPY activate.sh /hm/activate.sh
$SECRETS_COPY
$NAR_COPY
RUN chmod +x /hm/activate.sh
ENV HM_ACTIVATION_PATH=/nix/store/$RESULT_BASENAME
ENV HM_USER=$HM_USER
ENTRYPOINT ["/bin/bash", "/hm/activate.sh"]
DOCKERFILE_EOF

    log "Docker context ready: $DOCKER_CTX ($(du -sh "$DOCKER_CTX" | cut -f1))"
    log "  Closure: ${CLOSURE_SIZE}MB, ${CLOSURE_COUNT} store paths"
    echo "$RESULT" > "$SERVICE_DIR/.closure-path"
}
