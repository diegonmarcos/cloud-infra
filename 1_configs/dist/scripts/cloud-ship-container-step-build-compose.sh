# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/scripts/cloud-ship-container-step-build-compose.sh
# ║   Engine : 1_configs/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Step: Compose build + push — builds GHCR images from dockerfile_inline
# Builds all services in docker-compose.yml that have a build: section
# and pushes them to GHCR. Requires GHCR login before calling.
# Sourced by cloud-ship-container-engine.sh

step_compose_build() {
    CURRENT_STEP="compose-build"
    [ ! -d "$DIST_DIR" ] && { log "No dist/ -- run build first"; return 1; }
    [ ! -f "$COMPOSE_FILE" ] && { log "No compose file ($COMPOSE_FILE)"; return 1; }

    # Docker CLI required (installed in cloud-builder image)
    if ! command -v docker >/dev/null 2>&1; then
        log_warn "Docker CLI not available — skipping compose-build"
        return 0
    fi

    # Check if docker-compose.yml has any build: sections. Two forms:
    #   dockerfile_inline:  (mkGhcrBuild pattern — authelia, caddy, umami…)
    #   dockerfile:         (file-based build context — crawlee-cloud's
    #                        vendored assets/repo with docker/Dockerfile.*)
    # The step's contract (header) is "all services with a build: section";
    # the old inline-only grep silently skipped file-based builds, so their
    # GHCR images were never built/pushed and compose-up on the VM (which
    # is forced --no-build by doctrine) died with 'pull access denied'.
    # NOTE: engine.nix serialises compose as JSON-style YAML — keys are
    # QUOTED ("dockerfile":), so the pattern must tolerate quotes.
    if ! grep -qE '"?dockerfile(_inline)?"?[[:space:]]*:' "$COMPOSE_FILE" 2>/dev/null; then
        log "No build sections (dockerfile/dockerfile_inline) in docker-compose.yml -- skipping compose-build"
        return 0
    fi

    log "Building + pushing GHCR images from docker-compose.yml"
    cd "$DIST_DIR"

    # GHCR login — vault PAT first (owner-scoped, has write:packages and works
    # even when GHA $GITHUB_TOKEN is denied by package access lists / fork
    # context); then GHA env; then `gh` CLI (interactive devs).
    VAULT_GHCR_TOKEN_PATH="${VAULT_GHCR_TOKEN_PATH:-${HOME}/git/vault/A0_keys/providers/github/api-key_opaque/token}"
    GHCR_USER="${GHCR_USER:-diegonmarcos}"
    # Logins are guarded with `|| true` (mirrors step_docker): inside the
    # cloud-builder ~/.docker/config.json is a RO bind mount, so docker login
    # fails with 'Error saving credentials: rename ...: device or resource
    # busy' even though the runner is ALREADY logged in. Unguarded, set -e +
    # pipefail killed the whole step before the build ran (run 27416130512).
    # A genuinely broken auth still surfaces at `docker compose build --push`.
    if [ -f "$VAULT_GHCR_TOKEN_PATH" ]; then
        cat "$VAULT_GHCR_TOKEN_PATH" | docker login ghcr.io -u "$GHCR_USER" --password-stdin 2>&1 \
            | grep -vE '(^WARNING|credential helper|password will be stored|Error saving credentials)' || true
    elif [ -n "${GITHUB_TOKEN:-}" ]; then
        echo "$GITHUB_TOKEN" | docker login ghcr.io -u "$GITHUB_ACTOR" --password-stdin 2>&1 \
            | grep -vE '(^WARNING|credential helper|password will be stored|Error saving credentials)' || true
    elif command -v gh >/dev/null 2>&1; then
        gh auth token | docker login ghcr.io -u "$(gh api user --jq .login)" --password-stdin 2>&1 \
            | grep -vE '(^WARNING|credential helper|password will be stored|Error saving credentials)' || true
    else
        log_warn "No GHCR credentials — skipping push (build-only)"
        docker compose build
        return 0
    fi

    # Platform from build.json docker.arch (declarative, no hostname inference)
    ARCH="${DOCKER_ARCH:-amd64}"
    PLATFORM="linux/$ARCH"
    log "compose-build platform: $PLATFORM (from docker.arch)"
    # ── Arch guard (no QEMU, no cross-arch fallback — same doctrine as the
    # runner matrix). `docker compose build` compiles on the HOST arch no
    # matter what platform we log; when the workflow's builder-image
    # resolution fails (e.g. stale III_unix submodule pointer, run
    # 27409752538) the engine silently ran on the amd64 GHA runner, pushed
    # amd64 images for an arm64 target, and the VM died with exec-format-
    # error. FAIL LOUDLY instead.
    _HOST_ARCH=$(uname -m)
    case "$_HOST_ARCH" in
        x86_64)        _HOST_ARCH="amd64" ;;
        aarch64|arm64) _HOST_ARCH="arm64" ;;
    esac
    if [ "$_HOST_ARCH" != "$ARCH" ]; then
        # Dispatch to the arch-matching runner (same registry step_docker
        # uses: build-workflows.json .runners[arch].host). rsync the dist/
        # tree (compose file + build contexts like assets/repo) and run
        # docker compose build --push natively there.
        RUNNERS_JSON=""
        for _p in \
            "/app/build-workflows.json" \
            "${CLOUD_ROOT:-$SERVICE_DIR/../..}/1_configs/dist/build-workflows.json" \
            "$SRC_DIR/build-workflows.json"; do
            [ -f "$_p" ] && { RUNNERS_JSON="$_p"; break; }
        done
        RUNNER_HOST=""
        [ -n "$RUNNERS_JSON" ] && RUNNER_HOST="$(jq -r --arg a "$ARCH" '.runners[$a].host // empty' "$RUNNERS_JSON")"
        if [ -z "$RUNNER_HOST" ]; then
            log_error "compose-build arch mismatch (host=$_HOST_ARCH target=$ARCH) and no .runners[$ARCH].host in build-workflows.json — cannot build."
            return 1
        fi
        log "compose-build: arch mismatch (host=$_HOST_ARCH target=$ARCH) — dispatching to $RUNNER_HOST"
        REMOTE_CB_DIR="/tmp/compose-build-${SERVICE_NAME}"
        rsync -azL --delete "$DIST_DIR/" "$RUNNER_HOST:$REMOTE_CB_DIR/" || {
            log_error "compose-build: rsync to $RUNNER_HOST failed"
            return 1
        }
        # GHCR login on the runner — vault PAT via stdin (never on disk there).
        _CB_TOK=""
        [ -f "$VAULT_GHCR_TOKEN_PATH" ] && _CB_TOK="$(cat "$VAULT_GHCR_TOKEN_PATH")"
        [ -z "$_CB_TOK" ] && _CB_TOK="${GITHUB_TOKEN:-}"
        if [ -n "$_CB_TOK" ]; then
            printf '%s' "$_CB_TOK" | ssh "$RUNNER_HOST" "docker login ghcr.io -u $GHCR_USER --password-stdin" >/dev/null 2>&1 || true
        fi
        if ssh "$RUNNER_HOST" "cd $REMOTE_CB_DIR && DOCKER_BUILDKIT=1 docker compose -f compose/docker-compose.yml --project-directory . build --no-cache --push" 2>&1 \
            | while IFS= read -r line; do printf "[compose-build@remote] %s\n" "$line"; done; then
            log "compose-build (remote on $RUNNER_HOST) OK"
            return 0
        fi
        log_error "compose-build (remote on $RUNNER_HOST) FAILED"
        return 1
    fi
    # Build + push all services with build: sections (verbose output)
    log "── dockerfile_inline content ──"
    grep -A20 'dockerfile_inline:' "$COMPOSE_FILE" || true
    log "── docker compose build --push ──"
    COMPOSE_BUILD_OK=""
    # --project-directory "$DIST_DIR": relative build contexts in compose.nix
    # (e.g. crawlee's "./assets/repo") are written for the deploy step's
    # `--project-directory .` run from dist/. Without the same flag here,
    # compose resolves them against the compose FILE's dir (dist/compose/)
    # and the context is missing.
    if DOCKER_BUILDKIT=1 docker compose -f "$COMPOSE_FILE" --project-directory "$DIST_DIR" build --no-cache --push 2>&1 | while IFS= read -r line; do
        printf "[compose-build] %s\n" "$line"
    done; then
        COMPOSE_BUILD_OK=true
    fi

    if [ -z "$COMPOSE_BUILD_OK" ]; then
        log_error "compose-build FAILED — aborting ship to prevent deploying stale image"
        return 1
    fi

    DOCKER_IMAGE_CHANGED=true
    # Signal parent shell (background jobs can't set parent vars)
    echo "1" > "$SERVICE_DIR/.image-changed"
    log "GHCR images built and pushed"

    # Verify all pushed packages are public (CRITICAL)
    if command -v gh >/dev/null 2>&1; then
        grep -o 'ghcr.io/diegonmarcos/[^:]*' "$COMPOSE_FILE" 2>/dev/null | sort -u | while read -r img; do
            PKG_NAME=$(echo "$img" | awk -F/ '{print $NF}')
            PKG_VIS=$(gh api "/user/packages/container/${PKG_NAME}" --jq '.visibility' 2>/dev/null || echo "unknown")
            if [ "$PKG_VIS" = "private" ]; then
                log_error "PRIVATE PACKAGE: $PKG_NAME — push from GHA to make public"
            fi
        done
    fi
}
