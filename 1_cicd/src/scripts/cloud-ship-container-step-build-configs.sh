# Step: Push configs image to GHCR (dist/ -> busybox wrapper -> GHCR)
# Sourced by cloud-ship-container-engine.sh — do not execute directly

step_configs_push() {
    CURRENT_STEP="configs-push"
    # Disable set -e within this function — a non-zero from any single
    # command was bailing out the whole backgrounded subshell silently
    # under `set -e` from the engine, leaving the dispatch with the
    # bare "WARNING: configs-push failed" and zero diagnostic info.
    # Per-step error handling below logs the exact failure point.
    set +e
    [ ! -d "$DIST_DIR" ] && { log "No dist/ — skipping configs push"; return 0; }
    [ ! -f "$COMPOSE_FILE" ] && { log "No compose file ($COMPOSE_FILE) — skipping configs push"; return 0; }

    CONFIGS_IMAGE="${DOCKER_REGISTRY:-ghcr.io/diegonmarcos}/${SERVICE_NAME}-configs:latest"

    # Skip if dist/ unchanged AND arch unchanged. Without DOCKER_ARCH in
    # the hash, a service whose docker.arch was added later (e.g. arm64
    # for oci-apps services) sees an unchanged hash and skips pushing —
    # the GHCR image stays amd64-only and the arm64 VM hits "exec format
    # error" on deploy.
    CONFIGS_HASH=$(find "$DIST_DIR" -type f ! -name 'Dockerfile.configs' ! -name '.configs-hash' -exec sha256sum {} \; 2>/dev/null | sort | sha256sum | cut -c1-16)
    CONFIGS_HASH="${CONFIGS_HASH}-${DOCKER_ARCH:-amd64}"
    OLD_CONFIGS_HASH=$(cat "$SERVICE_DIR/.configs-hash" 2>/dev/null || echo "")
    if [ "$CONFIGS_HASH" = "$OLD_CONFIGS_HASH" ] && [ -n "$CONFIGS_HASH" ]; then
        log "Configs unchanged — skipping push ($CONFIGS_HASH)"
        return 0
    fi
    log "configs-push start (hash=$CONFIGS_HASH, arch=${DOCKER_ARCH:-amd64})"

    # GHCR login — INLINE fall-through (GITHUB_TOKEN → vault PAT → gh). Inlined,
    # not a shared helper: the lib's ghcr_login was not in scope here at runtime
    # ("ghcr_login: command not found" broke configs-push, 2026-06-23). Falls
    # through on FAILURE (not just a missing/unset credential), so an expired
    # token still reaches the next method; skip the push if every method fails.
    #
    # ORDER IS LOAD-BEARING — GITHUB_TOKEN MUST be tried first, exactly as
    # step_docker does. A GHCR package's visibility is fixed at CREATION and
    # there is NO API to change it later (PATCH/PUT/POST on
    # /user/packages/container/{pkg}[/visibility] all 404, verified 2026-08-31).
    # A package first pushed by a GHA job using GITHUB_TOKEN is repo-scoped and
    # inherits the public source repo's visibility; one first pushed with the
    # vault PAT is user-scoped and PRIVATE FOREVER, fixable only by deleting it
    # and re-pushing from GHA.
    #
    # This block used to try the vault PAT FIRST. ship.yml mounts cloud-vault
    # into the builder container, so in GHA the PAT was present and won, and
    # every configs image was born private+unlinked. That is precisely why
    # openobserve-configs, wireguard-mesh-configs, wireguard-mesh-ws-tunnel-configs
    # and tools-http-to-smtp-proxy-api-configs all show repository=NONE, while the
    # -binaries packages built by step_docker (GITHUB_TOKEN-first) are repo-linked.
    _vault_tok="${VAULT_GHCR_TOKEN_PATH:-${HOME}/git/cloud-vault/A0_keys/providers/github/api-key_opaque/token}"
    _ghcr_user="${GHCR_USER:-diegonmarcos}"
    if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_ACTOR:-}" ] && \
         printf '%s' "$GITHUB_TOKEN" | docker login ghcr.io -u "$GITHUB_ACTOR" --password-stdin >/dev/null 2>&1; then
        log "GHCR login OK (env GITHUB_TOKEN — package will be repo-scoped/public)"
    elif [ -f "$_vault_tok" ] && docker login ghcr.io -u "$_ghcr_user" --password-stdin < "$_vault_tok" >/dev/null 2>&1; then
        log "GHCR login OK (vault)"
    elif command -v gh >/dev/null 2>&1 && \
         gh auth token 2>/dev/null | docker login ghcr.io -u "$(gh api user --jq .login 2>/dev/null || echo "$_ghcr_user")" --password-stdin >/dev/null 2>&1; then
        log "GHCR login OK (gh)"
    else
        log "No usable GHCR credentials — skipping configs push"; return 0
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

    # Cross-arch: respect build.json:.docker.arch (DOCKER_ARCH set in orchestrator).
    # Without --platform the configs image inherits the build host's arch, so
    # an amd64 desktop pushes amd64 configs that fail with "exec format error"
    # on arm64 VMs (oci-apps). The Dockerfile.configs only does FROM busybox +
    # COPY + CMD — no arch-specific code — so cross-arch works without QEMU
    # because busybox:latest is a multi-arch manifest. Pre-pull the matching
    # variant first so docker build doesn't have to resolve cross-arch.
    CONFIGS_PLATFORM_FLAG=""
    if [ -n "${DOCKER_ARCH:-}" ]; then
        CONFIGS_PLATFORM_FLAG="--platform linux/${DOCKER_ARCH}"
        docker pull --platform "linux/${DOCKER_ARCH}" busybox:latest 2>/dev/null || true
    fi

    log "Building configs image: $CONFIGS_IMAGE${DOCKER_ARCH:+ (arch=$DOCKER_ARCH)}"
    # Restore dist/ to how we found it. Every exit path from here on must go
    # through this, including the failure paths: the generated .dockerignore is
    # itself part of the CONFIGS_HASH input, and bailing out without restoring
    # left the real .dockerignore in .bak — which the next run overwrites at the
    # top of this block, losing the original permanently.
    _restore_dist() {
        rm -f "$DIST_DIR/Dockerfile.configs"
        if [ -f "$DIST_DIR/.dockerignore.bak" ]; then
            mv "$DIST_DIR/.dockerignore.bak" "$DIST_DIR/.dockerignore"
        else
            rm -f "$DIST_DIR/.dockerignore"
        fi
    }

    docker build $CONFIGS_PLATFORM_FLAG -q -t "$CONFIGS_IMAGE" -f "$DIST_DIR/Dockerfile.configs" "$DIST_DIR" || {
        _restore_dist
        log_warn "Configs image build failed (non-fatal)"
        return 0
    }
    # Capture the push status BEFORE any pipe — `docker push ... | tail` reports
    # tail's exit code, so a `denied: permission_denied: write_package` used to
    # sail through as success. That mattered more than it looks: the hash below
    # is what the next run compares against to decide whether to rebuild, so
    # recording it after a failed push made the failure permanently sticky —
    # every later run saw an unchanged hash, skipped the push, and kept
    # deploying stale configs while logging "Pushed".
    push_out=$(docker push "$CONFIGS_IMAGE" 2>&1)
    push_rc=$?
    echo "$push_out" | tail -3

    _restore_dist

    if [ "$push_rc" -ne 0 ]; then
        # Still non-fatal, matching the build-failure path above — but the hash
        # is NOT recorded, so the next run retries instead of skipping.
        log_warn "Configs image push FAILED (rc=$push_rc): $CONFIGS_IMAGE — deploy continues with the previously published configs; hash not recorded so the next run retries"
        return 0
    fi

    echo "$CONFIGS_HASH" > "$SERVICE_DIR/.configs-hash"
    log "Pushed configs image: $CONFIGS_IMAGE ($CONFIGS_HASH) — secrets EXCLUDED"
}
