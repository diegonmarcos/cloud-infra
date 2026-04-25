# Step: Build Docker image, push to GHCR
# Sourced by cloud-ship-container-engine.sh — do not execute directly

step_docker() {
    # jq returns the literal "null" for missing paths; treat both as empty.
    case "${DOCKER_IMAGE:-}" in
        ""|null) log "No docker.image in build.json -- skipping"; return 0 ;;
    esac

    CURRENT_STEP="docker"
    FULL_IMAGE="${DOCKER_REGISTRY:+$DOCKER_REGISTRY/}$DOCKER_IMAGE"
    DOCKERFILE="${DOCKER_FILE:-Dockerfile}"
    SHA_TAG="${GITHUB_SHA:-$(git -C "$SERVICE_DIR" rev-parse HEAD 2>/dev/null || echo local)}"

    # Architecture from build.json (declarative, no hostname inference)
    ARCH="${DOCKER_ARCH:-amd64}"
    PLATFORM="linux/$ARCH"
    log "Docker build: $FULL_IMAGE (arch: $ARCH, runner: ${RUNNER:-auto})"

    # Smart hash: skip rebuild when src/ AND target arch unchanged
    # (arch must be part of the key — same src built for different arch produces different image)
    LOCAL_HASH=$(find "$SRC_DIR" -type f -not -path '*/node_modules/*' -not -path '*/.git/*' -not -name 'secrets.yaml' -exec sha256sum {} \; 2>/dev/null | sort | sha256sum | cut -c1-16)
    LOCAL_HASH="${LOCAL_HASH}-${ARCH}"
    if [ -n "$DEPLOY_HOST" ] && [ -n "$DEPLOY_PATH" ]; then
        REMOTE_HASH=$(ssh $SSH_OPTS "$DEPLOY_HOST" "cat $DEPLOY_PATH/.docker-src-hash 2>/dev/null" 2>/dev/null || true)
        if [ "$LOCAL_HASH" = "$REMOTE_HASH" ]; then
            # Trust the hash ONLY if the binaries image actually exists on GHCR.
            # A prior failed-push deploy still rsyncs .docker-src-hash to the VM,
            # so without this check we'd short-circuit forever and step_compose
            # would fail on the VM with "denied: denied" pulling a missing image.
            BINARIES_IMG="${DOCKER_REGISTRY:+$DOCKER_REGISTRY/}${DOCKER_IMAGE}-binaries:latest"
            if docker manifest inspect "$BINARIES_IMG" >/dev/null 2>&1; then
                log "Docker src unchanged ($LOCAL_HASH) — skipping"
                return 0
            else
                log "Docker src unchanged ($LOCAL_HASH) but $BINARIES_IMG missing on GHCR — forcing rebuild"
            fi
        else
            [ -n "$REMOTE_HASH" ] && log "Docker src changed ($REMOTE_HASH -> $LOCAL_HASH)"
        fi
    fi

    # ── Native build: build inside cloud-builder, package into minimal image ──
    NATIVE_CMD="$(get_config docker.native_build.cmd)"
    NATIVE_TYPE="$(get_config docker.native_build.type)"  # binary (default) or app
    NATIVE_BINARY="$(get_config docker.native_build.binary)"
    NATIVE_BASE="$(get_config docker.native_build.base_image)"
    NATIVE_APT="$(get_config docker.native_build.apt)"
    NATIVE_ENTRYPOINT="$(get_config docker.native_build.entrypoint)"
    NATIVE_APP_DIR="$(get_config docker.native_build.app_dir)"
    NATIVE_ENV="$(get_config docker.native_build.env)"
    [ -z "$NATIVE_TYPE" ] && NATIVE_TYPE="binary"

    if [ -n "$NATIVE_CMD" ]; then
        # Convert entrypoint string to JSON array: "npx tsx index.ts" → ["npx","tsx","index.ts"]
        _entrypoint_json() {
            echo "$1" | node -e "const a=require('fs').readFileSync(0,'utf8').trim().split(/\s+/);console.log(JSON.stringify(a))" 2>/dev/null
        }

        mkdir -p "$DIST_DIR"
        APT_LINE=""
        [ -n "$NATIVE_APT" ] && APT_LINE="RUN apt-get update && apt-get install -y --no-install-recommends $NATIVE_APT && rm -rf /var/lib/apt/lists/*"
        ENV_LINE=""
        [ -n "$NATIVE_ENV" ] && ENV_LINE="ENV $NATIVE_ENV"

        if [ "$NATIVE_TYPE" = "image-wrapper" ]; then
            # image-wrapper: build happens INSIDE Docker (RUN), not on host
            # Pulls upstream image, bakes deps, pushes to GHCR — VMs only pull
            log "Image-wrapper build: $NATIVE_CMD (inside Docker)"
            CMD_LINE="CMD $(_entrypoint_json "$NATIVE_ENTRYPOINT")"
            # app_dir scopes which subdirectory to COPY (default: entire context)
            COPY_SRC="${NATIVE_APP_DIR:-.}"
            WORKDIR_PATH="/app"
            # Non-root user for security
            USER_LINE="RUN useradd -r -u 1000 appuser"
            USER_SWITCH="USER appuser"
            cat > "$DIST_DIR/Dockerfile.native" <<NEOF
FROM ${NATIVE_BASE:-node:22-slim}
${APT_LINE}
WORKDIR ${WORKDIR_PATH}
COPY ${COPY_SRC} ${WORKDIR_PATH}
RUN ${NATIVE_CMD}
${USER_LINE}
${USER_SWITCH}
${ENV_LINE}
LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
${CMD_LINE}
NEOF
            # Place Dockerfile in src/ so build context has access to app_dir
            cp "$DIST_DIR/Dockerfile.native" "$SRC_DIR/Dockerfile.native"
            DOCKERFILE="Dockerfile.native"
            BUILD_CONTEXT="$SRC_DIR"
            log "Image-wrapper packaged (base: ${NATIVE_BASE:-node:22-slim})"

        elif [ "$NATIVE_TYPE" = "app" ]; then
            # app: build on host, copy result into image (for node/npm where host build is needed)
            log "Native build (app): $NATIVE_CMD"
            export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/tmp/cargo-target}"
            (cd "$SRC_DIR" && eval "$NATIVE_CMD") 2>&1 | while IFS= read -r line; do printf "[native] %s\n" "$line"; done
            CMD_LINE="CMD $(_entrypoint_json "$NATIVE_ENTRYPOINT")"
            cat > "$DIST_DIR/Dockerfile.native" <<NEOF
FROM ${NATIVE_BASE:-node:22-slim}
${APT_LINE}
${ENV_LINE}
WORKDIR /app
COPY . /app
ENTRYPOINT []
LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
${CMD_LINE}
NEOF
            # Place Dockerfile in src/ so build context has access to app files
            cp "$DIST_DIR/Dockerfile.native" "$SRC_DIR/Dockerfile.native"
            DOCKERFILE="Dockerfile.native"
            BUILD_CONTEXT="$SRC_DIR"
            log "Native app packaged (type=app)"
        else
            if [ -z "$NATIVE_BINARY" ]; then
                log_error "native_build.binary required for type=binary"
                return 1
            fi
            # Run the native build command (missing in the original — the
            # binary-path check below was checking for an output that was
            # never produced). For Rust this is `cargo build --release`.
            export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$SRC_DIR/target}"
            log "Native build (binary): $NATIVE_CMD (CARGO_TARGET_DIR=$CARGO_TARGET_DIR)"
            (cd "$SRC_DIR" && eval "$NATIVE_CMD") 2>&1 \
                | while IFS= read -r line; do printf "[native] %s\n" "$line"; done

            # Check CARGO_TARGET_DIR first (cargo writes there), then src/ relative
            BINARY_PATH="$SRC_DIR/$NATIVE_BINARY"
            _CARGO_BIN="$CARGO_TARGET_DIR/release/$(basename "$NATIVE_BINARY")"
            [ -f "$_CARGO_BIN" ] && BINARY_PATH="$_CARGO_BIN"
            if [ ! -f "$BINARY_PATH" ]; then
                log_error "Native build produced no binary at $NATIVE_BINARY (also checked $_CARGO_BIN)"
                return 1
            fi
            cp "$BINARY_PATH" "$DIST_DIR/"
            BINARY_NAME=$(basename "$NATIVE_BINARY")
            cat > "$DIST_DIR/Dockerfile.native" <<NEOF
FROM ${NATIVE_BASE:-debian:bookworm-slim}
${APT_LINE}
COPY ${BINARY_NAME} /usr/local/bin/${BINARY_NAME}
LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
CMD ["${BINARY_NAME}"]
NEOF
            DOCKERFILE="Dockerfile.native"
            log "Native binary packaged: $BINARY_NAME ($(du -sh "$DIST_DIR/$BINARY_NAME" | cut -f1))"
        fi
    fi

    # Build context: use what image-wrapper set, else prefer dist/ if Dockerfile exists there, else src/
    if [ -z "${BUILD_CONTEXT:-}" ]; then
        BUILD_CONTEXT="$SRC_DIR"
        if [ -d "$DIST_DIR" ] && [ -f "$DIST_DIR/$DOCKERFILE" ]; then
            BUILD_CONTEXT="$DIST_DIR"
        fi
    fi
    DOCKERFILE_PATH="$BUILD_CONTEXT/$DOCKERFILE"

    # Data-driven skip: services using compose `dockerfile_inline` (mkGhcrBuild)
    # produce the Dockerfile as a string inside dist/docker-compose.yml, not as
    # a physical file. step_docker has nothing to build here — compose-build
    # owns the image. No physical Dockerfile + no native_build.cmd = declarative
    # no-op. Covers authelia, hickory-dns, caddy, umami, redis — they all
    # declare docker.image (so the earlier null-guard doesn't fire) but have
    # no src/Dockerfile because the inline content lives in compose.
    if [ ! -f "$DOCKERFILE_PATH" ] && [ -z "$NATIVE_CMD" ]; then
        log "No Dockerfile at $DOCKERFILE_PATH and no native_build.cmd -- compose-build owns image; skipping"
        return 0
    fi

    # GHCR login
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        echo "$GITHUB_TOKEN" | docker login ghcr.io -u "$GITHUB_ACTOR" --password-stdin 2>/dev/null
    elif command -v gh >/dev/null 2>&1; then
        gh auth token 2>/dev/null | docker login ghcr.io -u "$(gh api user --jq .login 2>/dev/null)" --password-stdin 2>/dev/null
    fi

    # ── Resolve runner from cloud-data-runners.json (data-driven) ─────────
    # Declared architecture matrix: amd64 → local GHA, arm64 → oci-apps cloud-builder-x.
    # No QEMU. No cross-arch fallback. If the declared runner is unreachable
    # we FAIL LOUDLY — silent degradation was the bug that masked hundreds
    # of exec-format-error builds.
    RUNNERS_JSON=""
    for _p in \
        "${CLOUD_ROOT:-$SERVICE_DIR/../..}/2_configs/dist/cloud-data-runners.json" \
        "${CLOUD_ROOT:-$SERVICE_DIR/../..}/cloud-data-runners.json" \
        "$SRC_DIR/cloud-data-runners.json"; do
        [ -f "$_p" ] && { RUNNERS_JSON="$_p"; break; }
    done
    if [ -z "$RUNNERS_JSON" ]; then
        log_error "cloud-data-runners.json not found — cannot resolve runner for arch=$ARCH"
        return 1
    fi

    RUNNER_TYPE="$(jq -r --arg a "$ARCH" '.runners[$a].type // empty' "$RUNNERS_JSON")"
    RUNNER_HOST="$(jq -r --arg a "$ARCH" '.runners[$a].host // empty' "$RUNNERS_JSON")"
    RUNNER_IMAGE="$(jq -r --arg a "$ARCH" '.runners[$a].builder_image // empty' "$RUNNERS_JSON")"

    if [ -z "$RUNNER_TYPE" ]; then
        log_error "No runner declared for arch=$ARCH in $(basename "$RUNNERS_JSON"). Add .runners[\"$ARCH\"] or change docker.arch in build.json."
        return 1
    fi

    log "Runner for arch=$ARCH: type=$RUNNER_TYPE${RUNNER_HOST:+ host=$RUNNER_HOST}"

    # The compose layer (compose.nix in every service) references
    # `${buildJson.name}-binaries:latest` per the manifest schema in
    # _shared/engine.nix (images.binaries.repo). The engine MUST push both
    # tags — `<name>:latest` (canonical) and `<name>-binaries:latest`
    # (referenced by every dist/compose/docker-compose.yml). Without the
    # second push, first-ever ship of any v2 service hits "denied: denied"
    # on the VM at `docker compose pull` time.
    BINARIES_IMAGE="${FULL_IMAGE}-binaries"

    case "$RUNNER_TYPE" in
        local)
            log "Local build: $FULL_IMAGE"
            DOCKER_BUILDKIT=1 docker build \
                --network host \
                --platform "$PLATFORM" \
                --no-cache \
                --progress=plain \
                --tag "$FULL_IMAGE:latest" \
                --tag "$FULL_IMAGE:$SHA_TAG" \
                --tag "$BINARIES_IMAGE:latest" \
                --file "$DOCKERFILE_PATH" \
                "$BUILD_CONTEXT/" 2>&1 | while IFS= read -r line; do printf "[docker] %s\n" "$line"; done
            docker push "$FULL_IMAGE:latest" 2>&1 | while IFS= read -r line; do printf "[docker] %s\n" "$line"; done
            docker push "$FULL_IMAGE:$SHA_TAG" 2>&1 | while IFS= read -r line; do printf "[docker] %s\n" "$line"; done
            docker push "$BINARIES_IMAGE:latest" 2>&1 | while IFS= read -r line; do printf "[docker] %s\n" "$line"; done
            ;;

        ssh)
            [ -z "$RUNNER_HOST" ]  && { log_error "runners[$ARCH].host missing in $(basename "$RUNNERS_JSON")"; return 1; }
            [ -z "$RUNNER_IMAGE" ] && { log_error "runners[$ARCH].builder_image missing in $(basename "$RUNNERS_JSON")"; return 1; }

            # Readiness flag set by dispatch's multiplex warmup; fall back to a
            # live probe for out-of-CI invocations (CLI / Dagu). NO silent
            # degradation — if the host is dead, we exit 1.
            _ready_var="CLOUD_BUILDER_$(echo "$ARCH" | tr '[:lower:]' '[:upper:]')_READY"
            if [ "$(eval "echo \${$_ready_var:-}")" != "1" ]; then
                if ! ssh $SSH_OPTS "$RUNNER_HOST" true 2>/dev/null; then
                    log_error "cloud-builder for arch=$ARCH unreachable (host=$RUNNER_HOST). This is an illegal state — not falling back."
                    return 1
                fi
            fi

            REMOTE_BUILD_DIR="/tmp/${SERVICE_NAME}-docker-build"
            log "Remote build on $RUNNER_HOST via $RUNNER_IMAGE"
            ssh $SSH_OPTS "$RUNNER_HOST" "mkdir -p $REMOTE_BUILD_DIR"
            rsync -avzL --delete "$BUILD_CONTEXT/" "$RUNNER_HOST:$REMOTE_BUILD_DIR/"
            ssh $SSH_OPTS "$RUNNER_HOST" "docker run --rm \
                -v /var/run/docker.sock:/var/run/docker.sock \
                -v \$HOME/.docker/config.json:/root/.docker/config.json:ro \
                -v $REMOTE_BUILD_DIR:/workspace -w /workspace \
                $RUNNER_IMAGE \
                docker build --no-cache --progress=plain -t $FULL_IMAGE:latest -t $BINARIES_IMAGE:latest -f $DOCKERFILE . 2>&1" | while IFS= read -r line; do printf "[builder-x-$RUNNER_HOST] %s\n" "$line"; done
            ssh $SSH_OPTS "$RUNNER_HOST" "ionice -c3 nice -n19 docker push $FULL_IMAGE:latest 2>&1" | while IFS= read -r line; do printf "[docker-$RUNNER_HOST] %s\n" "$line"; done
            ssh $SSH_OPTS "$RUNNER_HOST" "ionice -c3 nice -n19 docker push $BINARIES_IMAGE:latest 2>&1" | while IFS= read -r line; do printf "[docker-$RUNNER_HOST] %s\n" "$line"; done
            ssh $SSH_OPTS "$RUNNER_HOST" "rm -rf $REMOTE_BUILD_DIR"
            ;;

        *)
            log_error "Unknown runner type '$RUNNER_TYPE' in $(basename "$RUNNERS_JSON") for arch=$ARCH (valid: local, ssh)"
            return 1
            ;;
    esac

    log "Pushed $FULL_IMAGE:latest"
    log "Pushed $BINARIES_IMAGE:latest"

    # Ensure both GHCR packages are public — flip via gh API if not already.
    # GITHUB_TOKEN works because both images carry the
    # org.opencontainers.image.source label that links them to this repo.
    _ensure_public() {
        local pkg="$1"
        if ! command -v gh >/dev/null 2>&1; then return 0; fi
        local vis
        vis=$(gh api "/user/packages/container/${pkg}" --jq '.visibility' 2>/dev/null || echo "unknown")
        case "$vis" in
            public)
                log "Package $pkg: public ✓"
                ;;
            private|internal)
                log "Package $pkg: $vis — flipping to public"
                if gh api --method PUT "/user/packages/container/${pkg}/visibility" -f visibility=public >/dev/null 2>&1; then
                    log "Package $pkg → public"
                else
                    log_warn "Package $pkg: could not flip to public (may need manual fix via GitHub UI)"
                fi
                ;;
            unknown|"")
                log_warn "Package $pkg: visibility check skipped (gh API unavailable)"
                ;;
        esac
    }
    PKG_NAME=$(echo "$FULL_IMAGE" | awk -F/ '{print $NF}')
    BINARIES_PKG_NAME=$(echo "$BINARIES_IMAGE" | awk -F/ '{print $NF}')
    _ensure_public "$PKG_NAME"
    _ensure_public "$BINARIES_PKG_NAME"

    mkdir -p "$DIST_DIR"
    echo "$LOCAL_HASH" > "$DIST_DIR/.docker-src-hash"
    touch "$SERVICE_DIR/.image-changed"
    DOCKER_IMAGE_CHANGED=true

    # Extract binary if needed (e.g. Rust binaries)
    if [ -n "$DOCKER_BINARY" ]; then
        log "Extracting binary from image"
        docker pull "$FULL_IMAGE:latest"
        CONTAINER_ID=$(docker create "$FULL_IMAGE:latest")
        docker cp "$CONTAINER_ID:$DOCKER_BINARY" "/tmp/${SERVICE_NAME}-binary"
        docker rm "$CONTAINER_ID"
        log "Extracted binary ($(du -h "/tmp/${SERVICE_NAME}-binary" | cut -f1))"
    fi
}
