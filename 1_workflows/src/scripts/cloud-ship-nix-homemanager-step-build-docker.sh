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

    # ── Collect runtime closure ──
    log "Collecting runtime closure..."
    DOCKER_CTX="$DIST_DIR/docker-ctx"
    [ -d "$DOCKER_CTX" ] && chmod -R u+w "$DOCKER_CTX" 2>/dev/null || true
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

    # ── Nix DB dump (for --load-db on target VM) ──
    log "Exporting nix DB dump..."
    nix-store --dump-db $(nix-store -qR "$RESULT") > "$DOCKER_CTX/nix-db-dump.txt" 2>/dev/null || {
        log "ERROR: nix-store --dump-db failed"
        return 1
    }
    REG_SIZE=$(du -sh "$DOCKER_CTX/nix-db-dump.txt" 2>/dev/null | cut -f1 || echo "?")
    log "DB dump: $REG_SIZE"

    # ── Generate activate.sh ──
    RESULT_BASENAME=$(basename "$RESULT")
    cat > "$DOCKER_CTX/activate.sh" <<'ACTIVATE_EOF'
#!/bin/bash
set -euo pipefail
HOST="${HM_HOST_ROOT:-/host}"
HM_USER="${HM_USER:?HM_USER env var required}"
ACTIVATION="$HOST$HM_ACTIVATION_PATH/activate"

log() { printf '[hm-activate] %s\n' "$1"; }

# ── Copy nix store paths to host (skip existing — content-addressed) ──
log "Copying nix store paths to host..."
COPIED=0; SKIPPED=0
for p in /nix/store/*; do
    [ ! -e "$p" ] && continue
    base=$(basename "$p")
    if [ -e "$HOST/nix/store/$base" ]; then
        SKIPPED=$((SKIPPED + 1))
    else
        cp -a "$p" "$HOST/nix/store/$base" && COPIED=$((COPIED + 1))
    fi
done
log "Store paths: $COPIED copied, $SKIPPED skipped (already on host)"

# ── Copy DB dump to host (registration happens natively, not in container) ──
if [ -f "/hm/nix-db-dump.txt" ]; then
    cp /hm/nix-db-dump.txt "$HOST/tmp/.hm-nix-db-dump.txt"
    log "DB dump copied to host /tmp/"
else
    log "ERROR: /hm/nix-db-dump.txt not found"
    exit 1
fi

# ── Create nix command symlinks (HM activate needs them) ──
NIX_DIR="$HOST/nix/var/nix/profiles/default/bin"
if [ -d "$NIX_DIR" ] && [ -x "$NIX_DIR/nix" ]; then
    for cmd in nix-build nix-instantiate nix-env nix-store nix-channel; do
        [ ! -e "$NIX_DIR/$cmd" ] && ln -sf nix "$NIX_DIR/$cmd" 2>/dev/null && log "Created $cmd symlink"
    done
fi

# ── Write activation path for native activate step ──
echo "$HM_ACTIVATION_PATH" > "$HOST/tmp/.hm-activation-path"
log "Container done — activation path: $HM_ACTIVATION_PATH"
ACTIVATE_EOF

    # ── Generate Dockerfile ──
    cat > "$DOCKER_CTX/Dockerfile" <<DOCKERFILE_EOF
FROM ghcr.io/diegonmarcos/user-dev-x86-deb-nix-hm:latest
USER root
LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
LABEL org.opencontainers.image.description="Home-Manager activation image for $SERVICE_NAME"
COPY nix-store/ /nix/store/
COPY activate.sh /hm/activate.sh
COPY nix-db-dump.txt /hm/nix-db-dump.txt
RUN chmod +x /hm/activate.sh
ENV HM_ACTIVATION_PATH=/nix/store/$RESULT_BASENAME
ENV HM_USER=$HM_USER
ENTRYPOINT ["/bin/bash", "/hm/activate.sh"]
DOCKERFILE_EOF

    log "Docker context ready: $DOCKER_CTX ($(du -sh "$DOCKER_CTX" | cut -f1))"
    log "  Closure: ${CLOSURE_SIZE}MB, ${CLOSURE_COUNT} store paths"
    echo "$RESULT" > "$SERVICE_DIR/.closure-path"
}
