# Step: Docker push (build image + push to GHCR)
# Sourced by cloud-ship-nix-homemanager-engine.sh — do not execute directly

step_docker_push() {
    [ -z "$HM_IMAGE" ] && { log "ERROR: hm.image not set in build.json"; return 1; }

    DOCKER_CTX="$DIST_DIR/docker-ctx"
    [ ! -d "$DOCKER_CTX" ] && { log "ERROR: No docker-ctx/ — run docker-package first"; return 1; }

    PLATFORM="${HM_PLATFORM:-linux/amd64}"
    SHA_TAG="$(git rev-parse --short HEAD 2>/dev/null || echo 'latest')"

    # Login to GHCR if token available
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        echo "$GITHUB_TOKEN" | docker login ghcr.io -u "${GITHUB_ACTOR:-diegonmarcos}" --password-stdin 2>/dev/null
    fi

    log "Building + pushing $HM_IMAGE ($PLATFORM)"
    if command -v docker >/dev/null 2>&1 && docker buildx version >/dev/null 2>&1; then
        run_logged "docker buildx build + push" \
            docker buildx build \
            --platform "$PLATFORM" \
            --push \
            -t "$HM_IMAGE:latest" \
            -t "$HM_IMAGE:$SHA_TAG" \
            "$DOCKER_CTX"
    else
        # Fallback: regular docker build (no multi-arch, no push)
        run_logged "docker build" docker build -t "$HM_IMAGE:latest" "$DOCKER_CTX"
        run_logged "docker push latest" docker push "$HM_IMAGE:latest"
        run_logged "docker tag+push sha" docker tag "$HM_IMAGE:latest" "$HM_IMAGE:$SHA_TAG" && docker push "$HM_IMAGE:$SHA_TAG"
    fi

    log "Pushed $HM_IMAGE:latest + $HM_IMAGE:$SHA_TAG"

    # Make package public (GHCR defaults to private even for public repos)
    PKG_NAME=$(echo "$HM_IMAGE" | sed 's|ghcr.io/[^/]*/||')
    if command -v gh >/dev/null 2>&1; then
        gh api --method PUT "/user/packages/container/${PKG_NAME}/visibility" \
            -f visibility=public 2>/dev/null && log "Package $PKG_NAME set to public" \
            || log "WARN: could not set package visibility (may need manual fix)"
    fi
}
