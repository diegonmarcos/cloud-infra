# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_workflows/src/scripts/cloud-ship-nix-homemanager-step-deploy-push.sh
# ║   Engine : 1_workflows/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Step: Docker push (build image + push to GHCR)
# Sourced by cloud-ship-nix-homemanager-engine.sh — do not execute directly

step_docker_push() {
    [ -z "$HM_IMAGE" ] && { log "ERROR: hm.image not set in build.json"; return 1; }

    DOCKER_CTX="$DIST_DIR/docker-ctx"
    [ ! -d "$DOCKER_CTX" ] && { log "ERROR: No docker-ctx/ — run docker-package first"; return 1; }

    PLATFORM="${HM_PLATFORM:-linux/amd64}"
    SHA_TAG="$(git rev-parse --short HEAD 2>/dev/null || echo 'latest')"

    # Login to GHCR. The cloud-builder container mounts the host's
    # ${HOME}/.docker/config.json :ro (per cb_containers-builders/src/docker/
    # compose.yaml), so the runner's prior `docker login` is already present.
    # A new in-container `docker login` would write to /root/.docker/config.json
    # which is read-only → "Error saving credentials: ... device or resource
    # busy" and the script aborts with set -e + pipefail.
    # Skip re-login if ghcr.io credentials are already in the mounted config.
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        if grep -q '"ghcr.io"' "${HOME}/.docker/config.json" 2>/dev/null; then
            log "GHCR auth: reusing host-mounted ~/.docker/config.json (skipping re-login)"
        elif ! echo "$GITHUB_TOKEN" | docker login ghcr.io -u "${GITHUB_ACTOR:-diegonmarcos}" --password-stdin; then
            log "ERROR: docker login to ghcr.io failed (user=${GITHUB_ACTOR:-diegonmarcos})"
            return 1
        fi
    fi

    log "Building + pushing $HM_IMAGE ($PLATFORM)"
    if command -v docker >/dev/null 2>&1 && docker buildx version >/dev/null 2>&1; then
        # Wrapped in run_with_retry. Two failure modes covered:
        #   1. Stall: docker buildx --push hangs (NET I/O = 0) on residential connections
        #      with large nix closures → `timeout` enforces deadline, retry kicks in.
        #   2. Stale state: a prior killed push leaves buildkit's "what I uploaded"
        #      tracker referencing blobs the registry never received → next push fails
        #      with "content digest <sha>: not found" referencing the orphan digest.
        #      RETRY_RECOVERY_CMD restarts buildkit between attempts to clear that state.
        # Retry knobs in build.json: build.retry.{attempts,timeout_secs,backoff_secs}.
        # NOTE: avoid `awk '... exit'` in a pipe under set -o pipefail — early
        # awk exit closes the pipe → docker gets SIGPIPE (141) → script exits
        # silently. Read the whole inspect output, then grep with || true to
        # never fail the pipe.
        BUILDX_BUILDER="$( { docker buildx inspect --bootstrap 2>/dev/null || true; } | grep -E '^Name:' | head -1 | awk '{print $2}' )"
        BUILDKIT_CONTAINER="buildx_buildkit_${BUILDX_BUILDER:-default}0"
        export RETRY_RECOVERY_CMD="docker restart ${BUILDKIT_CONTAINER} 2>/dev/null && sleep 3 || true"
        # --provenance=false + --sbom=false: omit attestation manifests so the
        # pushed manifest list has ONLY the architecture manifests. Docker on
        # the target VM (moby-engine 27.x with containerd-shim-runc-v2) reads
        # the manifest list and fails with "unsupported shim version (3)" if
        # buildx pushed an "unknown/unknown" attestation entry alongside the
        # arch entries — the daemon can't pick a platform and falls back to
        # the attestation manifest, which has no usable runtime config.
        run_with_retry "docker buildx build + push" \
            docker buildx build \
            --platform "$PLATFORM" \
            --provenance=false \
            --sbom=false \
            --push \
            -t "$HM_IMAGE:latest" \
            -t "$HM_IMAGE:$SHA_TAG" \
            "$DOCKER_CTX"
        unset RETRY_RECOVERY_CMD
    else
        # Fallback: regular docker build (no multi-arch, no push)
        run_logged    "docker build"      docker build -t "$HM_IMAGE:latest" "$DOCKER_CTX"
        run_with_retry "docker push latest" docker push "$HM_IMAGE:latest"
        run_logged    "docker tag sha"    docker tag "$HM_IMAGE:latest" "$HM_IMAGE:$SHA_TAG"
        run_with_retry "docker push sha"   docker push "$HM_IMAGE:$SHA_TAG"
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
