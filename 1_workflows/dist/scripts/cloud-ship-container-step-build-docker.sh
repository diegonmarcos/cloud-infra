# Step: Build Docker image, push to GHCR
# Sourced by cloud-ship-container-engine.sh — do not execute directly

step_docker() {
    [ -z "$DOCKER_IMAGE" ] && { log "No docker.image in build.json -- skipping"; return 0; }

    CURRENT_STEP="docker"
    FULL_IMAGE="${DOCKER_REGISTRY:+$DOCKER_REGISTRY/}$DOCKER_IMAGE"
    DOCKERFILE="${DOCKER_FILE:-Dockerfile}"
    SHA_TAG="${GITHUB_SHA:-$(git -C "$SERVICE_DIR" rev-parse HEAD 2>/dev/null || echo local)}"

    # Architecture from build.json (declarative, no hostname inference)
    ARCH="${DOCKER_ARCH:-amd64}"
    PLATFORM="linux/$ARCH"
    log "Docker build: $FULL_IMAGE (arch: $ARCH, runner: ${RUNNER:-auto})"

    # Smart hash: skip rebuild when src/ unchanged
    LOCAL_HASH=$(find "$SRC_DIR" -type f -not -path '*/node_modules/*' -not -path '*/.git/*' -not -name 'secrets.yaml' -exec sha256sum {} \; 2>/dev/null | sort | sha256sum | cut -c1-16)
    if [ -n "$DEPLOY_HOST" ] && [ -n "$DEPLOY_PATH" ]; then
        REMOTE_HASH=$(ssh $SSH_OPTS "$DEPLOY_HOST" "cat $DEPLOY_PATH/.docker-src-hash 2>/dev/null" 2>/dev/null || true)
        if [ "$LOCAL_HASH" = "$REMOTE_HASH" ]; then
            log "Docker src unchanged ($LOCAL_HASH) — skipping"
            return 0
        fi
        [ -n "$REMOTE_HASH" ] && log "Docker src changed ($REMOTE_HASH -> $LOCAL_HASH)"
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
        log "Native build ($NATIVE_TYPE): $NATIVE_CMD"
        # CARGO_TARGET_DIR: prevent rust builds from polluting src/
        export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/tmp/cargo-target}"
        (cd "$SRC_DIR" && eval "$NATIVE_CMD") 2>&1 | while IFS= read -r line; do printf "[native] %s\n" "$line"; done

        mkdir -p "$DIST_DIR"
        APT_LINE=""
        [ -n "$NATIVE_APT" ] && APT_LINE="RUN apt-get update && apt-get install -y --no-install-recommends $NATIVE_APT && rm -rf /var/lib/apt/lists/*"
        ENV_LINE=""
        [ -n "$NATIVE_ENV" ] && ENV_LINE="ENV $NATIVE_ENV"

        # Convert entrypoint string to JSON array: "npx tsx index.ts" → ["npx","tsx","index.ts"]
        _entrypoint_json() {
            echo "$1" | node -e "const a=require('fs').readFileSync(0,'utf8').trim().split(/\s+/);console.log(JSON.stringify(a))" 2>/dev/null
        }

        if [ "$NATIVE_TYPE" = "app" ]; then
            CMD_LINE="CMD $(_entrypoint_json "$NATIVE_ENTRYPOINT")"
            cat > "$DIST_DIR/Dockerfile.native" <<NEOF
FROM ${NATIVE_BASE:-node:22-slim}
${APT_LINE}
${ENV_LINE}
WORKDIR /app
COPY . /app
LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
${CMD_LINE}
NEOF
            DOCKERFILE="Dockerfile.native"
            log "Native app packaged (type=app)"
        else
            if [ -z "$NATIVE_BINARY" ]; then
                log_error "native_build.binary required for type=binary"
                return 1
            fi
            # Check CARGO_TARGET_DIR first (if set), then src/ relative
            BINARY_PATH="$SRC_DIR/$NATIVE_BINARY"
            [ -n "${CARGO_TARGET_DIR:-}" ] && [ -f "$CARGO_TARGET_DIR/release/$(basename "$NATIVE_BINARY")" ] && \
                BINARY_PATH="$CARGO_TARGET_DIR/release/$(basename "$NATIVE_BINARY")"
            if [ ! -f "$BINARY_PATH" ]; then
                log_error "Native build produced no binary at $NATIVE_BINARY (also checked $CARGO_TARGET_DIR)"
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

    # Build context: prefer dist/ if Dockerfile exists there, else src/
    BUILD_CONTEXT="$SRC_DIR"
    if [ -d "$DIST_DIR" ] && [ -f "$DIST_DIR/$DOCKERFILE" ]; then
        BUILD_CONTEXT="$DIST_DIR"
    fi
    DOCKERFILE_PATH="$BUILD_CONTEXT/$DOCKERFILE"

    # GHCR login
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        echo "$GITHUB_TOKEN" | docker login ghcr.io -u "$GITHUB_ACTOR" --password-stdin 2>/dev/null
    elif command -v gh >/dev/null 2>&1; then
        gh auth token 2>/dev/null | docker login ghcr.io -u "$(gh api user --jq .login 2>/dev/null)" --password-stdin 2>/dev/null
    fi

    # Dispatch based on runner
    case "${RUNNER:-auto}" in
        auto)
            HOST_ARCH=$(uname -m)
            case "$HOST_ARCH" in
                x86_64)  HOST_ARCH_DOCKER="amd64" ;;
                aarch64) HOST_ARCH_DOCKER="arm64" ;;
                *)       HOST_ARCH_DOCKER="$HOST_ARCH" ;;
            esac

            if [ "$ARCH" = "$HOST_ARCH_DOCKER" ]; then
                # Native build — same arch, no QEMU needed
                log "Auto-runner: native ($HOST_ARCH_DOCKER = $ARCH)"
            elif [ "$ARCH" = "arm64" ] && ssh -o ConnectTimeout=5 $SSH_OPTS oci-apps true 2>/dev/null; then
                # ARM build needed, oci-apps reachable — build there natively
                log "Auto-runner: oci-apps (native arm64)"
                RUNNER="oci-apps"
                REMOTE_BUILD_DIR="/tmp/${SERVICE_NAME}-docker-build"
                log "Building $FULL_IMAGE on oci-apps (native $ARCH)"
                ssh $SSH_OPTS "oci-apps" "mkdir -p $REMOTE_BUILD_DIR"
                rsync -avzL --delete "$BUILD_CONTEXT/" "oci-apps:$REMOTE_BUILD_DIR/"
                ssh $SSH_OPTS "oci-apps" "cd $REMOTE_BUILD_DIR && DOCKER_BUILDKIT=1 BUILDKIT_PROGRESS=plain docker build --no-cache --progress=plain -t $FULL_IMAGE:latest -f $DOCKERFILE . 2>&1" | while IFS= read -r line; do printf "[docker-oci-apps] %s\n" "$line"; done
                ssh $SSH_OPTS "oci-apps" "ionice -c3 nice -n19 docker push $FULL_IMAGE:latest 2>&1" | while IFS= read -r line; do printf "[docker-oci-apps] %s\n" "$line"; done
                ssh $SSH_OPTS "oci-apps" "rm -rf $REMOTE_BUILD_DIR"
                # Skip the local build below
                return 0
            else
                # Cross-arch build with QEMU
                log "Auto-runner: local + QEMU (cross-compile $HOST_ARCH_DOCKER → $ARCH)"
            fi

            # Local build (native or QEMU cross-compile)
            log "Building $FULL_IMAGE — docker build + push"
            DOCKER_BUILDKIT=1 docker build \
                --platform "$PLATFORM" \
                --no-cache \
                --progress=plain \
                --tag "$FULL_IMAGE:latest" \
                --tag "$FULL_IMAGE:$SHA_TAG" \
                --file "$DOCKERFILE_PATH" \
                "$BUILD_CONTEXT/" 2>&1 | while IFS= read -r line; do printf "[docker] %s\n" "$line"; done
            docker push "$FULL_IMAGE:latest" 2>&1 | while IFS= read -r line; do printf "[docker] %s\n" "$line"; done
            docker push "$FULL_IMAGE:$SHA_TAG" 2>&1 | while IFS= read -r line; do printf "[docker] %s\n" "$line"; done
            ;;

        local)
            log "Building $FULL_IMAGE — forced local build"
            DOCKER_BUILDKIT=1 docker build \
                --platform "$PLATFORM" \
                --no-cache \
                --progress=plain \
                --tag "$FULL_IMAGE:latest" \
                --tag "$FULL_IMAGE:$SHA_TAG" \
                --file "$DOCKERFILE_PATH" \
                "$BUILD_CONTEXT/" 2>&1 | while IFS= read -r line; do printf "[docker] %s\n" "$line"; done
            docker push "$FULL_IMAGE:latest" 2>&1 | while IFS= read -r line; do printf "[docker] %s\n" "$line"; done
            docker push "$FULL_IMAGE:$SHA_TAG" 2>&1 | while IFS= read -r line; do printf "[docker] %s\n" "$line"; done
            ;;

        oci-apps|oci-apps-1|oci-apps-2)
            # Build on ARM VM natively (fast, no QEMU)
            REMOTE_BUILD_DIR="/tmp/${SERVICE_NAME}-docker-build"
            log "Building $FULL_IMAGE on $RUNNER (native $ARCH)"
            ssh $SSH_OPTS "$RUNNER" "mkdir -p $REMOTE_BUILD_DIR"
            rsync -avzL --delete "$BUILD_CONTEXT/" "$RUNNER:$REMOTE_BUILD_DIR/"
            ssh $SSH_OPTS "$RUNNER" "cd $REMOTE_BUILD_DIR && DOCKER_BUILDKIT=1 BUILDKIT_PROGRESS=plain docker build --no-cache --progress=plain -t $FULL_IMAGE:latest -f $DOCKERFILE . 2>&1" | while IFS= read -r line; do printf "[docker-$RUNNER] %s\n" "$line"; done
            ssh $SSH_OPTS "$RUNNER" "ionice -c3 nice -n19 docker push $FULL_IMAGE:latest 2>&1" | while IFS= read -r line; do printf "[docker-$RUNNER] %s\n" "$line"; done
            ssh $SSH_OPTS "$RUNNER" "rm -rf $REMOTE_BUILD_DIR"
            ;;

        *)
            log_error "Unknown runner: $RUNNER (valid: auto, local, oci-apps)"
            return 1
            ;;
    esac

    log "Pushed $FULL_IMAGE:latest"

    # Ensure GHCR package is public
    PKG_NAME=$(echo "$FULL_IMAGE" | awk -F/ '{print $NF}')
    if command -v gh >/dev/null 2>&1; then
        PKG_VIS=$(gh api "/user/packages/container/${PKG_NAME}" --jq '.visibility' 2>/dev/null || echo "unknown")
        if [ "$PKG_VIS" = "public" ]; then
            log "Package $PKG_NAME: public ✓"
        elif [ "$PKG_VIS" = "private" ]; then
            log_error "PRIVATE PACKAGE: $PKG_NAME — needs GHA push to make public"
        fi
    fi

    echo "$LOCAL_HASH" > "$SERVICE_DIR/.docker-src-hash-new"
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
