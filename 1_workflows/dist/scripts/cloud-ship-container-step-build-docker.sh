# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_workflows/src/scripts/cloud-ship-container-step-build-docker.sh
# ║   Engine : 1_workflows/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Step: Build Docker image, push to GHCR
# Sourced by cloud-ship-container-engine.sh — do not execute directly

step_docker() {
    # jq returns the literal "null" for missing paths; treat both as empty.
    case "${DOCKER_IMAGE:-}" in
        ""|null) log "No docker.image in build.json -- skipping"; return 0 ;;
    esac

    # Diagnostic: surface silent step_docker deaths.
    # The engine has `set -e`, and step_docker runs backgrounded with `&` —
    # any non-zero command outside `||`/`&&` chains aborts the function with
    # zero output, leaving the parent's `wait $PID_DOCKER` to log only
    # "docker build failed" with no clue WHERE. Surfaced 2026-04-27 (ship
    # run 24995653483): both c3-services-mcp + mail-mcp died ~0.5s after
    # `Native app packaged` with no log between that and the parent's error.
    #
    # ERR trap fires on every set -e exit; prints line + command + exit
    # code. RETURN trap clears both on function exit so traps don't leak
    # into other steps in the parallel block.
    _docker_err() {
        log_error "step_docker died at line $1 (exit $2): $3"
        return "$2"
    }
    trap '_docker_err "$LINENO" "$?" "$BASH_COMMAND"' ERR
    trap 'trap - ERR RETURN' RETURN

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
    NATIVE_USER="$(get_config docker.native_build.user)"  # appuser (default) | root
    [ -z "$NATIVE_TYPE" ] && NATIVE_TYPE="binary"
    [ -z "$NATIVE_USER" ] && NATIVE_USER="appuser"

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
            # Strip any stale host-side node_modules from the build context.
            # image-wrapper does the install inside the container; carrying a
            # stale node_modules across the rsync (which uses -L) breaks
            # intra-tree symlinks like node_modules/.bin/tsx → ../tsx/dist/cli.mjs
            # because dereferencing copies the bundled JS into .bin/ where its
            # sibling-relative imports no longer resolve. 2026-05-05.
            APP_DIR_REL_CLEAN="${NATIVE_APP_DIR:-.}"
            CLEAN_BASE="$SRC_DIR"
            [ "$APP_DIR_REL_CLEAN" != "." ] && CLEAN_BASE="$SRC_DIR/$APP_DIR_REL_CLEAN"
            if [ -d "$CLEAN_BASE/node_modules" ]; then
                log "Removing stale host node_modules: $CLEAN_BASE/node_modules"
                rm -rf "$CLEAN_BASE/node_modules"
            fi
            CMD_LINE="CMD $(_entrypoint_json "$NATIVE_ENTRYPOINT")"
            # app_dir scopes which subdirectory to COPY (default: entire context)
            COPY_SRC="${NATIVE_APP_DIR:-.}"
            WORKDIR_PATH="/app"
            # User switch is data-driven via build.json native_build.user.
            # Default "appuser" (non-root, security best practice).
            # Set "root" for services that need root inside the container
            # (e.g. /root/.ssh chown, host-uid:gid mounts that require root).
            if [ "$NATIVE_USER" = "root" ]; then
                USER_LINE=""
                USER_SWITCH=""
            else
                # UID 10001 + idempotent + -m (create home dir): avoids
                # collision with node:* base images that ship a `node` user
                # at UID 1000. -m gives appuser /home/appuser, which npx
                # needs for ~/.npm/_logs (without it npx errors with
                # "EACCES /home/appuser/.npm/_logs"). HOME env var is set
                # explicitly so it works even when the user-switch path
                # doesn't initialize HOME.
                USER_LINE="RUN id -u ${NATIVE_USER} >/dev/null 2>&1 || useradd -r -m -u 10001 ${NATIVE_USER}"
                USER_SWITCH="USER ${NATIVE_USER}
ENV HOME=/home/${NATIVE_USER}"
            fi
            # Also COPY build.json — services may read it at runtime for
            # data-driven config (FIRE RULE 4). e.g. google-personal-mcp
            # reads accounts[] from build.json. Without this, the COPY
            # ${COPY_SRC} only copies app_dir contents and build.json is
            # missing at /app/build.json.
            cat > "$DIST_DIR/Dockerfile.native" <<NEOF
FROM ${NATIVE_BASE:-node:22-slim}
${APT_LINE}
WORKDIR ${WORKDIR_PATH}
COPY ${COPY_SRC} ${WORKDIR_PATH}
COPY build.json ${WORKDIR_PATH}/build.json
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
            #
            # app_dir = subdirectory inside src/ that holds package.json /
            # package-lock.json / source files (default: "." — src/ itself).
            # Without this, services that nest their code under src/code/
            # (mail-mcp, mattermost-mcp, google-personal-mcp, …) hit
            # `npm ci: no package-lock.json` because cwd defaults to $SRC_DIR.
            APP_DIR_REL="${NATIVE_APP_DIR:-.}"
            BUILD_CWD="$SRC_DIR"
            [ "$APP_DIR_REL" != "." ] && BUILD_CWD="$SRC_DIR/$APP_DIR_REL"
            if [ ! -d "$BUILD_CWD" ]; then
                log_error "native_build.app_dir='$APP_DIR_REL' not found at $BUILD_CWD"
                return 1
            fi
            log "Native build (app): $NATIVE_CMD (cwd=$BUILD_CWD)"
            export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/tmp/cargo-target}"
            (cd "$BUILD_CWD" && eval "$NATIVE_CMD") 2>&1 | while IFS= read -r line; do printf "[native] %s\n" "$line"; done
            CMD_LINE="CMD $(_entrypoint_json "$NATIVE_ENTRYPOINT")"
            cat > "$DIST_DIR/Dockerfile.native" <<NEOF
FROM ${NATIVE_BASE:-node:22-slim}
${APT_LINE}
${ENV_LINE}
WORKDIR /app
COPY ${APP_DIR_REL} /app
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
            # Run the native build command. Honours optional native_build.app_dir
            # for projects where the Cargo workspace lives under a subdir of src/
            # (e.g. fin-api with workspace at src/code/Cargo.toml).
            APP_DIR_REL="${NATIVE_APP_DIR:-.}"
            BUILD_CWD="$SRC_DIR"
            [ "$APP_DIR_REL" != "." ] && BUILD_CWD="$SRC_DIR/$APP_DIR_REL"
            if [ ! -d "$BUILD_CWD" ]; then
                log_error "native_build.app_dir='$APP_DIR_REL' not found at $BUILD_CWD"
                return 1
            fi
            export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$BUILD_CWD/target}"
            log "Native build (binary): $NATIVE_CMD (cwd=$BUILD_CWD, CARGO_TARGET_DIR=$CARGO_TARGET_DIR)"
            (cd "$BUILD_CWD" && eval "$NATIVE_CMD") 2>&1 \
                | while IFS= read -r line; do printf "[native] %s\n" "$line"; done

            # Check CARGO_TARGET_DIR first (cargo writes there), then BUILD_CWD relative
            BINARY_PATH="$BUILD_CWD/$NATIVE_BINARY"
            _CARGO_BIN="$CARGO_TARGET_DIR/release/$(basename "$NATIVE_BINARY")"
            [ -f "$_CARGO_BIN" ] && BINARY_PATH="$_CARGO_BIN"
            if [ ! -f "$BINARY_PATH" ]; then
                log_error "Native build produced no binary at $NATIVE_BINARY (also checked $_CARGO_BIN)"
                return 1
            fi
            cp "$BINARY_PATH" "$DIST_DIR/"
            BINARY_NAME=$(basename "$NATIVE_BINARY")

            # Patch ELF interpreter from nix-store path to debian's standard.
            # Cargo builds on a NixOS host link the binary to a nix-store
            # ld-linux (/nix/store/.../glibc-2.x/lib/ld-linux-x86-64.so.2),
            # which doesn't exist inside debian:bookworm-slim → exec returns
            # "not found" with exit 127 (mail-puller regression, fixed
            # 2026-05-05). patchelf retargets to debian's standard path.
            # No-op if the binary already points to a debian-friendly ld.
            if command -v patchelf >/dev/null 2>&1; then
                _CUR_INTERP=$(patchelf --print-interpreter "$DIST_DIR/$BINARY_NAME" 2>/dev/null || echo "")
                if echo "$_CUR_INTERP" | grep -q '/nix/store/'; then
                    patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 "$DIST_DIR/$BINARY_NAME"
                    log "Patched ELF interpreter: $_CUR_INTERP -> /lib64/ld-linux-x86-64.so.2"
                fi
            else
                log "patchelf not on host PATH — binary may fail in container if linker path is nix-store"
            fi

            cat > "$DIST_DIR/Dockerfile.native" <<NEOF
FROM ${NATIVE_BASE:-debian:bookworm-slim}
${APT_LINE}
COPY ${BINARY_NAME} /usr/local/bin/${BINARY_NAME}
LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
CMD ["${BINARY_NAME}"]
NEOF
            DOCKERFILE="Dockerfile.native"
            # Pin context to DIST_DIR — the binary AND the Dockerfile.native
            # both live there. Without this, the default-context block below
            # fires the v2-engine path (dist/code/$ARCH/) when upstream_image
            # is set, which doesn't contain Dockerfile.native — docker build
            # then fails with "open Dockerfile.native: no such file or
            # directory" (mail-puller regression, fixed 2026-05-05).
            BUILD_CONTEXT="$DIST_DIR"
            log "Native binary packaged: $BINARY_NAME ($(du -sh "$DIST_DIR/$BINARY_NAME" | cut -f1))"
        fi
    fi

    # Build context: use what image-wrapper set, else prefer the v2-engine
    # arch-specific path (dist/code/<arch>/Dockerfile, emitted by
    # _shared/engine.nix mkCodeDockerfile) — but ONLY when build.json declares
    # an explicit `upstream_image`. Without an explicit upstream the engine
    # falls back to `alpine:latest` and emits a stub Dockerfile that has no
    # binary, which would silently push an empty image and break the service
    # (regression introduced 2026-05-02 — caused Caddy to exit immediately
    # because the binary wasn't in PATH). For services that use
    # `dockerfile_inline` in compose.nix (mkGhcrBuild pattern), compose-build
    # owns the image; this step is a no-op for them and the existing skip at
    # line ~205 handles it.
    UPSTREAM_DECL="$(get_config upstream_image)"
    if [ -z "${BUILD_CONTEXT:-}" ]; then
        BUILD_CONTEXT="$SRC_DIR"
        if [ -n "$UPSTREAM_DECL" ] \
           && [ -d "$DIST_DIR/code/$ARCH" ] \
           && [ -f "$DIST_DIR/code/$ARCH/Dockerfile" ]; then
            BUILD_CONTEXT="$DIST_DIR/code/$ARCH"
        elif [ -d "$DIST_DIR" ] && [ -f "$DIST_DIR/$DOCKERFILE" ]; then
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

    # GHCR login — best-effort.
    # The login is REDUNDANT inside cloud-builder: the GHA runner already
    # logged in before `docker compose run`, and ${HOME}/.docker/config.json
    # is bind-mounted RO into cloud-builder per cb_containers-builders compose.yaml.
    # The re-login fails with "permission denied" trying to write the RO
    # mount → previously aborted step_docker silently because of `2>/dev/null`
    # combined with set -e. Now: stderr is preserved (for debuggability) and
    # `|| true` keeps the pipeline going since downstream `docker push` will
    # surface its own error if auth is genuinely broken.
    # Surfaced 2026-04-27 (ship run 24998359368) by step_docker ERR trap.
    if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_ACTOR:-}" ]; then
        echo "$GITHUB_TOKEN" | docker login ghcr.io -u "$GITHUB_ACTOR" --password-stdin 2>&1 \
            | grep -vE '(^WARNING|credential helper|password will be stored)' || true
    elif command -v gh >/dev/null 2>&1; then
        gh auth token 2>/dev/null | docker login ghcr.io -u "$(gh api user --jq .login 2>/dev/null)" --password-stdin 2>&1 \
            | grep -vE '(^WARNING|credential helper|password will be stored)' || true
    fi

    # ── Resolve runner from cloud-data-runners.json (data-driven) ─────────
    # Declared architecture matrix: amd64 → local GHA, arm64 → oci-apps cloud-builder-x.
    # No QEMU. No cross-arch fallback. If the declared runner is unreachable
    # we FAIL LOUDLY — silent degradation was the bug that masked hundreds
    # of exec-format-error builds.
    RUNNERS_JSON=""
    for _p in \
        "/app/cloud-data-runners.json" \
        "${CLOUD_ROOT:-$SERVICE_DIR/../..}/2_configs/dist/cloud-data-runners.json" \
        "${CLOUD_ROOT:-$SERVICE_DIR/../..}/cloud-data/cloud-data-runners.json" \
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
    # Image identity: prefer III_unix/cb_containers-builders/build.json (the
    # producer's master). Back-compat: fall back to legacy
    # .runners[$a].builder_image in cloud-data-runners.json if master not
    # checked out. The legacy field may be removed once all consumers are
    # migrated; this fallback then becomes the only path that matters.
    RUNNER_IMAGE=""
    UNIX_MASTER=""
    for _u in \
        "${CLOUD_ROOT:-$SERVICE_DIR/../..}/III_unix/cb_containers-builders/build.json" \
        "$SRC_DIR/III_unix/cb_containers-builders/build.json"; do
        [ -f "$_u" ] && { UNIX_MASTER="$_u"; break; }
    done
    if [ -n "$UNIX_MASTER" ]; then
        _ghcr=$(jq -r '.images["cloud-builder-x-deb-nixhm"].ghcr // empty' "$UNIX_MASTER" 2>/dev/null)
        [ -n "$_ghcr" ] && [ "$_ghcr" != "null" ] && RUNNER_IMAGE="${_ghcr}:latest"
    fi
    if [ -z "$RUNNER_IMAGE" ]; then
        # Legacy fallback — runners.json mirror, kept for back-compat
        RUNNER_IMAGE="$(jq -r --arg a "$ARCH" '.runners[$a].builder_image // empty' "$RUNNERS_JSON")"
    fi

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
            # Layer-cache strategy: pull the previous published image and pass
            # it as --cache-from. Docker compares each instruction's layer hash
            # against the pulled image; identical layers are reused without
            # rebuild. `|| true` tolerates the first-ever build (no cached
            # image yet) — self-bootstraps from the second build onwards.
            # Single-stage Dockerfiles get ~90% cache hit; multi-stage (Rust)
            # only caches the final stage (cargo intermediate stage isn't in
            # the published image — accepted trade-off, no extra cache infra).
            docker pull "$FULL_IMAGE:latest" 2>/dev/null || true
            docker pull "$BINARIES_IMAGE:latest" 2>/dev/null || true
            DOCKER_BUILDKIT=1 docker build \
                --network host \
                --platform "$PLATFORM" \
                --cache-from "$FULL_IMAGE:latest" \
                --cache-from "$BINARIES_IMAGE:latest" \
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
            [ -z "$RUNNER_IMAGE" ] && { log_error "cloud-builder-x image not resolved (checked III_unix/cb_containers-builders/build.json [.images.cloud-builder-x-deb-nixhm.ghcr] and $(basename "$RUNNERS_JSON") [.runners[$ARCH].builder_image])"; return 1; }

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
            REMOTE_TOKEN_FILE="/tmp/${SERVICE_NAME}-ghcr-token"
            log "Remote build on $RUNNER_HOST via $RUNNER_IMAGE"
            ssh $SSH_OPTS "$RUNNER_HOST" "mkdir -p $REMOTE_BUILD_DIR"
            rsync -avzL --delete "$BUILD_CONTEXT/" "$RUNNER_HOST:$REMOTE_BUILD_DIR/"

            # GHCR token: read where vault IS available (this side — runner-side
            # cloud-builder has ~/git/vault mounted by ship.yml), then ship to
            # the remote VM via SSH stdin. Avoids requiring vault on every VM
            # that hosts cloud-builder-x. Surfaced 2026-04-27 (ship run
            # 24998852451): /home/ubuntu/git/vault on oci-apps was an empty
            # stub dir; cat'ing the token inside cloud-builder-x silently
            # failed → docker login failed → build/push failed → engine
            # logged misleading "Pushed" because the SSH | while-read pipe
            # swallowed the non-zero exit (no pipefail).
            VAULT_GHCR_TOKEN_PATH="${VAULT_GHCR_TOKEN_PATH:-/home/diego/git/vault/A0_keys/providers/github/api-key_opaque/token}"
            GHCR_USER="${GHCR_USER:-diegonmarcos}"
            GHCR_TOKEN_VAL=""
            if [ -f "$VAULT_GHCR_TOKEN_PATH" ]; then
                GHCR_TOKEN_VAL=$(cat "$VAULT_GHCR_TOKEN_PATH")
            elif [ -n "${GITHUB_TOKEN:-}" ]; then
                GHCR_TOKEN_VAL="$GITHUB_TOKEN"
            else
                log_error "no GHCR token available (vault: $VAULT_GHCR_TOKEN_PATH missing AND GITHUB_TOKEN unset)"
                return 1
            fi
            ssh $SSH_OPTS "$RUNNER_HOST" "umask 077 && cat > $REMOTE_TOKEN_FILE && chmod 0600 $REMOTE_TOKEN_FILE" <<<"$GHCR_TOKEN_VAL"

            # Ensure HOST docker daemon (which executes the `docker run` for
            # the runner image below) has fresh ghcr.io auth — the inner
            # cloud-builder-x container login (line 367) only authenticates
            # the container's own client, not the daemon that pulls the
            # runner image. Without this, first-ever `docker run` of the
            # cloud-builder-x runner on a VM whose ~/.docker/config.json
            # holds a stale ghs_* token fails with "denied: denied" pulling
            # the runner image, before any inside-container step can run.
            ssh $SSH_OPTS "$RUNNER_HOST" "cat $REMOTE_TOKEN_FILE | docker login ghcr.io -u $GHCR_USER --password-stdin >/dev/null"

            # Build + login + push happen INSIDE the cloud-builder-x container.
            # Token is mounted from the SSH-staged file (no vault dep on VM).
            # `set -o pipefail` so any failure in the | while-read pipe propagates
            # — without it, SSH-side build/push failures returned exit 0 and the
            # engine continued as if the push succeeded.
            #
            # `cd /workspace &&` — REQUIRED because cloud-builder-x's entrypoint
            # (cb_containers-builders/src/docker/entrypoint.sh:248-249) does
            # `cd $GIT_ROOT/cloud` before exec'ing the user command, OVERRIDING
            # docker's -w flag. Without the explicit cd, docker build runs from
            # /root/git/cloud and can't find Dockerfile.native (rsync'd to
            # /workspace). Surfaced 2026-04-27 (ship run 25000440517):
            # "ERROR: failed to read dockerfile: open Dockerfile.native: no such file or directory".
            set -o pipefail
            ssh $SSH_OPTS "$RUNNER_HOST" "docker run --rm \
                -v /var/run/docker.sock:/var/run/docker.sock \
                -v $REMOTE_TOKEN_FILE:/tmp/ghcr-token:ro \
                -v $REMOTE_BUILD_DIR:/workspace -w /workspace \
                $RUNNER_IMAGE \
                sh -c 'set -e; \
                    cd /workspace && \
                    cat /tmp/ghcr-token | docker login ghcr.io -u $GHCR_USER --password-stdin >/dev/null && \
                    echo \"[ghcr] login ok (cwd=\$(pwd))\" && \
                    (docker pull $FULL_IMAGE:latest 2>/dev/null || true) && \
                    (docker pull $BINARIES_IMAGE:latest 2>/dev/null || true) && \
                    docker build --cache-from $FULL_IMAGE:latest --cache-from $BINARIES_IMAGE:latest --progress=plain -t $FULL_IMAGE:latest -t $BINARIES_IMAGE:latest -f $DOCKERFILE . && \
                    docker push $FULL_IMAGE:latest && \
                    docker push $BINARIES_IMAGE:latest && \
                    docker logout ghcr.io >/dev/null 2>&1 || true' 2>&1" | while IFS= read -r line; do printf "[builder-x-$RUNNER_HOST] %s\n" "$line"; done
            set +o pipefail
            # chmod -R u+w: rsync -L dereferences nix-store-rooted symlinks
            # into read-only files (mode 444); without u+w, rm -rf fails and
            # masks the build's success with a fatal cleanup error.
            ssh $SSH_OPTS "$RUNNER_HOST" "rm -f $REMOTE_TOKEN_FILE; chmod -R u+w $REMOTE_BUILD_DIR 2>/dev/null; rm -rf $REMOTE_BUILD_DIR"
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
