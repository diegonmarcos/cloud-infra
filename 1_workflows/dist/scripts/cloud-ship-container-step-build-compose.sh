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

    # Check if docker-compose.yml has any build: sections
    if ! grep -q 'dockerfile_inline:' "$COMPOSE_FILE" 2>/dev/null; then
        log "No dockerfile_inline in docker-compose.yml -- skipping compose-build"
        return 0
    fi

    log "Building + pushing GHCR images from docker-compose.yml"
    cd "$DIST_DIR"

    # GHCR login (GHA provides GITHUB_TOKEN, local uses gh auth token)
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        echo "$GITHUB_TOKEN" | docker login ghcr.io -u "$GITHUB_ACTOR" --password-stdin
    elif command -v gh >/dev/null 2>&1; then
        gh auth token | docker login ghcr.io -u "$(gh api user --jq .login)" --password-stdin
    else
        log_warn "No GHCR credentials — skipping push (build-only)"
        docker compose build
        return 0
    fi

    # Platform from build.json docker.arch (declarative, no hostname inference)
    ARCH="${DOCKER_ARCH:-amd64}"
    PLATFORM="linux/$ARCH"
    log "compose-build platform: $PLATFORM (from docker.arch)"
    # Build + push all services with build: sections (verbose output)
    log "── dockerfile_inline content ──"
    grep -A20 'dockerfile_inline:' "$COMPOSE_FILE" || true
    log "── docker compose build --push ──"
    COMPOSE_BUILD_OK=""
    if DOCKER_BUILDKIT=1 docker compose -f "$COMPOSE_FILE" build --no-cache --push 2>&1 | while IFS= read -r line; do
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
