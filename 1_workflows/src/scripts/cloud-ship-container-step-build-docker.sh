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
    # RETURN trap also restores any pipefail state saved by the SSH-builder
    # branch (see `_SSH_PREV_PIPEFAIL` below). Without this, an early `return 1`
    # from anywhere inside the `ssh)` case branch (host/image probe failure,
    # rsync abort, dispatch timeout, …) would leave `set -o pipefail` enabled
    # in the parent shell and leak into subsequent steps. The textual
    # `set +o pipefail` is also issued at every explicit branch exit point so
    # the test contract can grep for it.
    _docker_return_cleanup() {
        if [ -n "${_SSH_PREV_PIPEFAIL:-}" ]; then
            set +o pipefail
            eval "$_SSH_PREV_PIPEFAIL"
        fi
        # Per-job DOCKER_CONFIG isolation cleanup — see DOCKER_CONFIG block
        # below. RETURN trap fires on every exit path (success, error, early
        # return), so the per-job dir is guaranteed to be removed even when
        # the SSH branch bails halfway through. `|| true` keeps cleanup
        # best-effort: failure to rm a tmp dir must never mask the real
        # step exit code.
        if [ -n "${_DOCKER_CONFIG_OWNED:-}" ] && [ -d "${_DOCKER_CONFIG_OWNED}" ]; then
            rm -rf "${_DOCKER_CONFIG_OWNED}" || true
            unset _DOCKER_CONFIG_OWNED
        fi
        trap - ERR RETURN
    }
    trap '_docker_err "$LINENO" "$?" "$BASH_COMMAND"' ERR
    trap '_docker_return_cleanup' RETURN

    # ── Per-job DOCKER_CONFIG isolation (rename-race fix) ─────────────────
    # GHA matrix jobs all run inside the cloud-builder image with HOME=/root,
    # so concurrent step_docker invocations would all write
    # /root/.docker/config.json. `docker login` does atomic temp+rename over
    # config.json — when two logins overlap, the second loses the rename
    # race with EBUSY ("rename ... device or resource busy"), aborting the
    # ship. Surfaced 2026-05-08 (gcp-proxy matrix run, http-to-smtp-proxy-api
    # never shipped). Setting DOCKER_CONFIG to a per-service+PID path makes
    # docker write to its own dir, eliminating the shared-file race.
    # Cleanup happens in _docker_return_cleanup so every exit path frees the
    # tmp dir. Per-service+PID keys also survive the legitimate case where a
    # single process re-enters step_docker (deploys won't collide on $$).
    DOCKER_CONFIG="/tmp/docker-config-${SERVICE_NAME:-default}-$$"
    mkdir -p "$DOCKER_CONFIG"
    export DOCKER_CONFIG
    _DOCKER_CONFIG_OWNED="$DOCKER_CONFIG"

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
            # Trust the hash ONLY if the binaries package actually exists on GHCR.
            # A prior failed-push deploy still rsyncs .docker-src-hash to the VM,
            # so without this check we'd short-circuit forever and step_compose
            # would fail on the VM with "denied: denied" pulling a missing image.
            #
            # Existence check via `gh api` (preferred over `docker manifest
            # inspect`):
            #   - gh API returns deterministic 404 vs 200, no auth-vs-missing
            #     ambiguity. `docker manifest inspect` could return failure on
            #     transient auth glitches even when the image existed (and
            #     vice versa) — caused 6 services (google-workspace-mcp,
            #     rig-agentic-{sonn,hai}, cloud-cgc-mcp, news-gdelt, postlite)
            #     to remain stale after the binaries-tag fix landed
            #     (8ec41cb5, 2026-04-25): src/ unchanged → skip path →
            #     never rebuilt → never pushed -binaries (Phase 16 contract).
            #   - gh API is also exactly what test_binaries_image_published.sh
            #     queries, so engine + test stay in lockstep.
            #   - Falls back to `docker manifest inspect` when gh is
            #     unavailable / unauthenticated (e.g. CI runners without gh).
            BINARIES_IMG="${DOCKER_REGISTRY:+$DOCKER_REGISTRY/}${DOCKER_IMAGE}-binaries:latest"
            BINARIES_PKG="${DOCKER_IMAGE}-binaries"
            # Existence is not enough — must also verify the manifest covers
            # the target $ARCH. Without the arch check, a service that's been
            # built only amd64 in the past skips rebuild forever, and the
            # arm64 VM hits "exec format error" on compose. `docker manifest
            # inspect` is the authoritative cross-arch query (.manifests[].
            # platform.architecture for multi-arch manifests, .architecture
            # for single-arch).
            _binaries_arch_match=0
            # `|| true` is required because the pipe's first command exits
            # non-zero when the manifest is missing (404). Engine has
            # `set -e -o pipefail` at the top, so without the tolerant
            # outer, the script aborts at the assignment instead of just
            # leaving _remote_archs empty for the rebuild path.
            _remote_archs=$( (docker manifest inspect "$BINARIES_IMG" 2>/dev/null | \
                jq -r '
                    if .manifests then
                        [.manifests[].platform.architecture] | join(",")
                    elif .architecture then
                        .architecture
                    else empty end' 2>/dev/null) || true )
            if [ -n "$_remote_archs" ] && echo ",$_remote_archs," | grep -q ",$ARCH,"; then
                _binaries_arch_match=1
            fi
            if [ "$_binaries_arch_match" = 1 ]; then
                log "Docker src unchanged ($LOCAL_HASH), $BINARIES_IMG covers arch=$ARCH — skipping"
                return 0
            else
                log "Docker src unchanged ($LOCAL_HASH) but $BINARIES_IMG missing or no arch=$ARCH variant (remote_archs=${_remote_archs:-none}) — forcing rebuild"
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

    # ── Type-A vendored-Dockerfile build_args ──
    # Services that ship their own Dockerfile (via nativeBuild.dockerfile in
    # the flake) can declare upstream-style --build-arg KEY=VALUE pairs
    # under docker.build_args in build.json (e.g. MM_PACKAGE pointing at the
    # arm64 tarball for Mattermost). Parsed into an array so values with
    # spaces / special chars survive both `local` and `ssh` build paths.
    declare -a BUILD_ARGS_ARR=()
    BUILD_ARGS_STR=""
    BUILD_ARGS_JSON="$(jq -c '.docker.build_args // empty' "$CONFIG" 2>/dev/null)"
    if [ -n "$BUILD_ARGS_JSON" ] && [ "$BUILD_ARGS_JSON" != "null" ] && [ "$BUILD_ARGS_JSON" != "{}" ]; then
        while IFS= read -r _kv; do
            [ -n "$_kv" ] || continue
            BUILD_ARGS_ARR+=(--build-arg "$_kv")
            # String form for the ssh heredoc branch (values are URLs / scalars
            # with no shell-sensitive chars; if that assumption ever changes,
            # we'd need a printf %q per-value pass before inlining).
            BUILD_ARGS_STR="$BUILD_ARGS_STR --build-arg $_kv"
        done < <(echo "$BUILD_ARGS_JSON" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
    fi

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
                # chown -R ${WORKDIR_PATH}: COPY preserves source file perms.
                # On a host with a restrictive umask (077) the COPYed app files
                # are mode 600 root-only, so after the USER switch appuser gets
                # EACCES reading its own /app/package.json and the container
                # crash-loops. chown the app tree to the runtime user (as root,
                # before the USER switch) so it's readable regardless of the
                # host umask — fully reproducible across build machines.
                USER_LINE="RUN id -u ${NATIVE_USER} >/dev/null 2>&1 || useradd -r -m -u 10001 ${NATIVE_USER}; chown -R ${NATIVE_USER} ${WORKDIR_PATH}"
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
ENTRYPOINT []
${CMD_LINE}
NEOF
            # Stamp the engine-generated Dockerfile.native with the canonical
            # GENERATED-FILE banner so test_service_header_present.sh passes.
            # Done BEFORE the cp into src/ so both copies carry the header.
            [ -x "$INJECT_HEADER" ] && "$INJECT_HEADER" stamp "$DIST_DIR/Dockerfile.native" "$DIST_DIR/Dockerfile.native" || true
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
            # Stamp the engine-generated Dockerfile.native with the canonical
            # GENERATED-FILE banner. See test_service_header_present.sh.
            [ -x "$INJECT_HEADER" ] && "$INJECT_HEADER" stamp "$DIST_DIR/Dockerfile.native" "$DIST_DIR/Dockerfile.native" || true
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
            BINARY_NAME=$(basename "$NATIVE_BINARY")
            NATIVE_BUILDER="$(get_config docker.native_build.builder_image)"
            if [ -n "$NATIVE_BUILDER" ]; then
                # ── In-container multi-stage compile (arch-correct by design) ──
                # The compile happens INSIDE docker, so it runs on whichever
                # runner the arch matrix dispatches the build to (arm64 →
                # oci-apps cloud-builder). This is the ONLY arch-safe path:
                # the legacy host-compile below produces a binary of the CI
                # host's arch — fin-api shipped an x86_64 ELF inside an
                # "arm64" image (e_machine=0x3E), kernel ENOEXEC → dash
                # fallback → 'Syntax error: "(" unexpected' (2026-06-11).
                # builder_image is declared per-service in build.json
                # (docker.native_build.builder_image) — data-driven, no
                # toolchain guessing here.
                log "Native build (binary, in-container): builder=$NATIVE_BUILDER cmd=$NATIVE_CMD"
                cat > "$DIST_DIR/Dockerfile.native" <<NEOF
FROM ${NATIVE_BUILDER} AS native-build
WORKDIR /build
COPY . /build
RUN ${NATIVE_CMD}
FROM ${NATIVE_BASE:-debian:bookworm-slim}
${APT_LINE}
COPY --from=native-build /build/${NATIVE_BINARY} /usr/local/bin/${BINARY_NAME}
LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
CMD ["${BINARY_NAME}"]
NEOF
                [ -x "$INJECT_HEADER" ] && "$INJECT_HEADER" stamp "$DIST_DIR/Dockerfile.native" "$DIST_DIR/Dockerfile.native" || true
                # Dockerfile must live inside the context so the remote-runner
                # rsync ($BUILD_CONTEXT/ → runner) carries it along.
                cp "$DIST_DIR/Dockerfile.native" "$BUILD_CWD/Dockerfile.native"
                DOCKERFILE="Dockerfile.native"
                BUILD_CONTEXT="$BUILD_CWD"
                log "Native binary packaged (in-container, context=$BUILD_CWD)"
                # Skip the host-compile path entirely.
                NATIVE_HOST_COMPILE=false
            else
                NATIVE_HOST_COMPILE=true
            fi
            if [ "$NATIVE_HOST_COMPILE" = "true" ]; then
            # ── Legacy host-compile path — host arch MUST match target ──
            # uname -m → docker arch nomenclature. A host-compiled binary is
            # the HOST's architecture no matter what --platform the later
            # docker build claims; shipping it cross-arch is a guaranteed
            # ENOEXEC on the VM. FAIL LOUDLY (same doctrine as the runner
            # matrix: no QEMU, no cross-arch fallback).
            _HOST_ARCH=$(uname -m)
            case "$_HOST_ARCH" in
                x86_64)         _HOST_ARCH="amd64" ;;
                aarch64|arm64)  _HOST_ARCH="arm64" ;;
            esac
            if [ -n "$ARCH" ] && [ "$_HOST_ARCH" != "$ARCH" ]; then
                log_error "native_build host-compile arch mismatch: host=$_HOST_ARCH target=$ARCH. Declare docker.native_build.builder_image (e.g. rust:1-bookworm) for an in-container multi-stage build on the arch-matching runner."
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
            # Stamp the engine-generated Dockerfile.native with the canonical
            # GENERATED-FILE banner. See test_service_header_present.sh.
            [ -x "$INJECT_HEADER" ] && "$INJECT_HEADER" stamp "$DIST_DIR/Dockerfile.native" "$DIST_DIR/Dockerfile.native" || true
            DOCKERFILE="Dockerfile.native"
            # Pin context to DIST_DIR — the binary AND the Dockerfile.native
            # both live there. Without this, the default-context block below
            # fires the v2-engine path (dist/code/$ARCH/) when upstream_image
            # is set, which doesn't contain Dockerfile.native — docker build
            # then fails with "open Dockerfile.native: no such file or
            # directory" (mail-puller regression, fixed 2026-05-05).
            BUILD_CONTEXT="$DIST_DIR"
            log "Native binary packaged: $BINARY_NAME ($(du -sh "$DIST_DIR/$BINARY_NAME" | cut -f1))"
            fi # NATIVE_HOST_COMPILE
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
    # Auto-detect Type B (upstream wrap) when build.json doesn't declare
    # upstream_image but the flake produced a dist/code/<arch>/Dockerfile
    # with a `FROM <upstream>` line. Avoids requiring every Type-B service
    # (authelia, vaultwarden, …) to redundantly mirror the FROM line in
    # build.json.
    if [ -z "$UPSTREAM_DECL" ] \
       && [ -f "$DIST_DIR/code/$ARCH/Dockerfile" ] \
       && grep -q '^FROM ' "$DIST_DIR/code/$ARCH/Dockerfile" 2>/dev/null; then
        UPSTREAM_DECL="$(grep -m1 '^FROM ' "$DIST_DIR/code/$ARCH/Dockerfile" | awk '{print $2}')"
        log "Type B auto-detected: upstream=${UPSTREAM_DECL} (from dist/code/$ARCH/Dockerfile)"
    fi
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

    # GHCR login — best-effort, three-tier fallback (mirrors the remote-runner
    # branch at the bottom of this file for uniform auth across local + remote):
    #
    #   1. Vault PAT (~/git/vault/...) — owner-scoped PAT with write:packages.
    #      ALWAYS works when vault is present. Tried FIRST because the GHA
    #      ephemeral $GITHUB_TOKEN has failed before with `denied:
    #      permission_denied: write_package` (forked PR context, package-level
    #      access lists, etc.); the vault PAT bypasses all of that.
    #   2. $GITHUB_TOKEN — GHA workflow ephemeral, when running inside GHA.
    #   3. `gh auth token` — interactive `gh` login (devs running locally).
    #
    # The login itself is REDUNDANT inside cloud-builder when the GHA runner
    # already logged in before `docker compose run` (${HOME}/.docker/config.json
    # is bind-mounted RO into cloud-builder per cb_containers-builders
    # compose.yaml). The re-login fails with "permission denied" trying to
    # write the RO mount → previously aborted step_docker silently because of
    # `2>/dev/null` combined with set -e. Now: stderr is preserved (for
    # debuggability) and `|| true` keeps the pipeline going since downstream
    # `docker push` will surface its own error if auth is genuinely broken.
    # Surfaced 2026-04-27 (ship run 24998359368) by step_docker ERR trap.
    VAULT_GHCR_TOKEN_PATH="${VAULT_GHCR_TOKEN_PATH:-${HOME}/git/vault/A0_keys/providers/github/api-key_opaque/token}"
    GHCR_USER="${GHCR_USER:-diegonmarcos}"
    if [ -f "$VAULT_GHCR_TOKEN_PATH" ]; then
        cat "$VAULT_GHCR_TOKEN_PATH" | docker login ghcr.io -u "$GHCR_USER" --password-stdin 2>&1 \
            | grep -vE '(^WARNING|credential helper|password will be stored)' || true
    elif [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_ACTOR:-}" ]; then
        echo "$GITHUB_TOKEN" | docker login ghcr.io -u "$GITHUB_ACTOR" --password-stdin 2>&1 \
            | grep -vE '(^WARNING|credential helper|password will be stored)' || true
    elif command -v gh >/dev/null 2>&1; then
        gh auth token 2>/dev/null | docker login ghcr.io -u "$(gh api user --jq .login 2>/dev/null)" --password-stdin 2>&1 \
            | grep -vE '(^WARNING|credential helper|password will be stored)' || true
    fi

    # ── Resolve runner from build-workflows.json (data-driven) ────────────
    # Declared architecture matrix: amd64 → local GHA, arm64 → oci-apps cloud-builder-x.
    # No QEMU. No cross-arch fallback. If the declared runner is unreachable
    # we FAIL LOUDLY — silent degradation was the bug that masked hundreds
    # of exec-format-error builds.
    # Source-of-truth: 1_workflows/build.json (.runners + .probe + .dispatch),
    # aggregated by 2_configs/build.sh into dist/build-workflows.json.
    # Migrated 2026-05-09 from the legacy runners.json under I_cloud-data/ (archived).
    RUNNERS_JSON=""
    for _p in \
        "/app/build-workflows.json" \
        "${CLOUD_ROOT:-$SERVICE_DIR/../..}/2_configs/dist/build-workflows.json" \
        "${CLOUD_ROOT:-$SERVICE_DIR/../..}/1_workflows/src/build-workflows.json" \
        "$SRC_DIR/build-workflows.json"; do
        [ -f "$_p" ] && { RUNNERS_JSON="$_p"; break; }
    done
    if [ -z "$RUNNERS_JSON" ]; then
        log_error "build-workflows.json not found — cannot resolve runner for arch=$ARCH"
        return 1
    fi

    RUNNER_TYPE="$(jq -r --arg a "$ARCH" '.runners[$a].type // empty' "$RUNNERS_JSON")"
    RUNNER_HOST="$(jq -r --arg a "$ARCH" '.runners[$a].host // empty' "$RUNNERS_JSON")"
    # Image identity: prefer III_unix/cb_containers-builders/build.json (the
    # producer's master). Back-compat: fall back to legacy
    # .runners[$a].builder_image in build-workflows.json if master not
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
        # Pull the per-arch tag (:amd64 / :arm64) instead of :latest. The
        # unix-repo build.sh publishes both per-arch tags AND a multi-arch
        # :latest manifest list — but :latest got clobbered to amd64-only
        # at some point on the GHCR push rotation (manifest combine step
        # didn't survive a subsequent single-arch push). Using :$ARCH is
        # what `docker manifest create` itself reads from — same source of
        # truth, arch-correct, immune to :latest regressions.
        # See log of ship run 27015547857 (2026-06-05) — exec format error
        # because :latest was amd64 on an arm64 host.
        [ -n "$_ghcr" ] && [ "$_ghcr" != "null" ] && RUNNER_IMAGE="${_ghcr}:${ARCH}"
    fi
    if [ -z "$RUNNER_IMAGE" ]; then
        # Legacy fallback — build-workflows.json mirror, kept for back-compat
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

    # ══════════════════════════════════════════════════════════════════════
    # RUNNER DESIGN (data-driven from build-workflows.json .runners[$ARCH])
    # ══════════════════════════════════════════════════════════════════════
    #   docker.arch=amd64  → RUNNER_TYPE=local → build on THIS x86 GHA runner.
    #   docker.arch=arm64  → RUNNER_TYPE=ssh   → build is DISPATCHED over SSH
    #                        into the cloud-builder-x-deb-nixhm:arm64 container
    #                        ON oci-apps (the ONLY ARM builder). GHA is x86-ONLY.
    #   No QEMU. No cross-arch fallback. Unreachable runner ⇒ FAIL LOUD.
    #
    #   BOTH paths MUST `docker build --platform "$PLATFORM"` (linux/$ARCH).
    #   The ssh path also passes `--cache-from <amd64 prior image>`; WITHOUT an
    #   explicit --platform the classic builder reuses those amd64 layers and
    #   silently emits an amd64 image on the arm64 host → every container then
    #   dies with "exec format error". --platform is load-bearing, not cosmetic.
    # ══════════════════════════════════════════════════════════════════════
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
            # ── Materialize symlinks in BUILD_CONTEXT (buildkit + EMLINK guard) ──
            # When src/ contains symlinks pointing OUTSIDE the build context
            # (e.g. src/build.json -> ../build.json, generated by build.sh setup),
            # buildkit's checksum step fails with "too many links". Resolve them
            # in-place; build.sh setup recreates the symlink on next run.
            if [ -d "$BUILD_CONTEXT" ]; then
                for _slink in "$BUILD_CONTEXT"/*; do
                    [ -L "$_slink" ] || continue
                    _real=$(readlink -f "$_slink") || continue
                    [ -f "$_real" ] || continue
                    rm -f "$_slink"
                    cp "$_real" "$_slink"
                done
            fi
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
                "${BUILD_ARGS_ARR[@]}" \
                "$BUILD_CONTEXT/" 2>&1 | while IFS= read -r line; do printf "[docker] %s\n" "$line"; done
            docker push "$FULL_IMAGE:latest" 2>&1 | while IFS= read -r line; do printf "[docker] %s\n" "$line"; done
            docker push "$FULL_IMAGE:$SHA_TAG" 2>&1 | while IFS= read -r line; do printf "[docker] %s\n" "$line"; done
            docker push "$BINARIES_IMAGE:latest" 2>&1 | while IFS= read -r line; do printf "[docker] %s\n" "$line"; done
            ;;

        ssh)
            [ -z "$RUNNER_HOST" ]  && { log_error "runners[$ARCH].host missing in $(basename "$RUNNERS_JSON")"; return 1; }
            [ -z "$RUNNER_IMAGE" ] && { log_error "cloud-builder-x image not resolved (checked III_unix/cb_containers-builders/build.json [.images.cloud-builder-x-deb-nixhm.ghcr] and $(basename "$RUNNERS_JSON") [.runners[$ARCH].builder_image])"; return 1; }

            # Save prior pipefail state and enable pipefail for the entire
            # SSH-builder branch. The branch contains multiple
            # `ssh ... | while IFS= read -r line` pipelines (tail-log streaming,
            # status polling) plus the GHCR token | docker login | ssh stdin
            # pipe. Without `set -o pipefail`, the pipeline's exit is the LAST
            # command's exit (typically `while read` → 0 on EOF), masking
            # genuine SSH/build/push failures upstream and silently returning 0
            # to step_docker. The misleading "Pushed" log line then runs even
            # when nothing was pushed. Surfaced 2026-04-27 (ship run
            # 24998852451). Prior state restored before exiting the branch
            # (search for `set +o pipefail` below) so options don't leak into
            # subsequent steps in the same shell.
            _SSH_PREV_PIPEFAIL=$(set +o | grep pipefail)
            set -o pipefail

            # ssh_with_retry / rsync_with_retry are defined in
            # cloud-ship-container-engine.sh (sourced before this step).
            # Override defaults from runners.json — same values used by the
            # probe loop above for consistency across all SSH/rsync calls
            # in the engine, not just this step.
            export SSH_RETRY_N=$(jq -r '.probe.retries // 3' "$RUNNERS_JSON" 2>/dev/null)
            export SSH_RETRY_BACKOFF=$(jq -r '.probe.backoff_seconds // 5' "$RUNNERS_JSON" 2>/dev/null)

            # Readiness flag set by dispatch's multiplex warmup; fall back to a
            # live probe for out-of-CI invocations (CLI / Dagu). NO silent
            # degradation — if the host is dead after retries, we exit 1.
            #
            # Retry/backoff loaded from runners.json (.probe.retries +
            # .probe.backoff_seconds + .probe.connect_timeout_seconds) — added
            # because single-shot probes failed the entire ship on transient
            # SSH timeouts (WG flap, sshd MaxStartups bursts under engine's
            # parallel block). Defaults are conservative: 3 retries × 5s.
            _ready_var="CLOUD_BUILDER_$(echo "$ARCH" | tr '[:lower:]' '[:upper:]')_READY"
            if [ "$(eval "echo \${$_ready_var:-}")" != "1" ]; then
                _probe_retries=$(jq -r '.probe.retries // 3' "$RUNNERS_JSON" 2>/dev/null)
                _probe_backoff=$(jq -r '.probe.backoff_seconds // 5' "$RUNNERS_JSON" 2>/dev/null)
                _probe_ctimeout=$(jq -r '.probe.connect_timeout_seconds // 10' "$RUNNERS_JSON" 2>/dev/null)
                _probe_ok=0
                _probe_attempt=0
                while [ "$_probe_attempt" -le "$_probe_retries" ]; do
                    if ssh $SSH_OPTS -o ConnectTimeout="$_probe_ctimeout" "$RUNNER_HOST" true 2>/dev/null; then
                        _probe_ok=1
                        break
                    fi
                    _probe_attempt=$((_probe_attempt + 1))
                    if [ "$_probe_attempt" -le "$_probe_retries" ]; then
                        log_warn "cloud-builder probe ${_probe_attempt}/${_probe_retries} failed (host=$RUNNER_HOST) — retrying in ${_probe_backoff}s"
                        sleep "$_probe_backoff"
                    fi
                done
                if [ "$_probe_ok" -ne 1 ]; then
                    log_error "cloud-builder for arch=$ARCH unreachable (host=$RUNNER_HOST) after ${_probe_retries} retries × ${_probe_backoff}s. This is an illegal state — not falling back."
                    return 1
                fi
            fi

            REMOTE_BUILD_DIR="/tmp/${SERVICE_NAME}-docker-build"
            REMOTE_TOKEN_FILE="/tmp/${SERVICE_NAME}-ghcr-token"
            log "Remote build on $RUNNER_HOST via $RUNNER_IMAGE"
            log "  [1/7] mkdir $REMOTE_BUILD_DIR on $RUNNER_HOST"
            ssh_with_retry "$RUNNER_HOST" "mkdir -p $REMOTE_BUILD_DIR"
            # rsync uses the user's ~/.ssh/config (already declares its own
            # ControlMaster mux). Forcing engine's SSH_OPTS via -e collided
            # with the user's master path, causing rsync handshakes to drop.
            # Transport-blip retry via rsync_with_retry (exit 12/30/255).
            log "  [2/7] rsync $BUILD_CONTEXT/ → $RUNNER_HOST:$REMOTE_BUILD_DIR/"
            rsync_with_retry -avzL --delete "$BUILD_CONTEXT/" "$RUNNER_HOST:$REMOTE_BUILD_DIR/"

            # GHCR token: read where vault IS available (this side — runner-side
            # cloud-builder has ~/git/vault mounted by ship.yml), then ship to
            # the remote VM via SSH stdin. Avoids requiring vault on every VM
            # that hosts cloud-builder-x. Surfaced 2026-04-27 (ship run
            # 24998852451): /home/ubuntu/git/vault on oci-apps was an empty
            # stub dir; cat'ing the token inside cloud-builder-x silently
            # failed → docker login failed → build/push failed → engine
            # logged misleading "Pushed" because the SSH | while-read pipe
            # swallowed the non-zero exit (no pipefail).
            VAULT_GHCR_TOKEN_PATH="${VAULT_GHCR_TOKEN_PATH:-${HOME}/git/vault/A0_keys/providers/github/api-key_opaque/token}"
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
            log "  [3/7] write GHCR token → $RUNNER_HOST:$REMOTE_TOKEN_FILE (vault path: $VAULT_GHCR_TOKEN_PATH)"
            # Stream the token to the remote temp file via SSH stdin in a single
            # printf | ssh pipe (pipefail is set above — a failure in printf or
            # ssh propagates and aborts the branch). The literal `ssh $SSH_OPTS`
            # form (not `ssh_with_retry`) is required so the engine's
            # SSH_OPTS-controlled mux is reused; the token never lands on disk
            # on the controller and never lives on the runner FS outside the
            # 0600 file we explicitly clean up at the end of the branch.
            printf '%s' "$GHCR_TOKEN_VAL" | ssh $SSH_OPTS "$RUNNER_HOST" "umask 077 && cat > $REMOTE_TOKEN_FILE && chmod 0600 $REMOTE_TOKEN_FILE"

            # Repair: docker login does atomic temp+rename over
            # /root/.docker/config.json. If a stale `docker run -v` ever
            # bind-mounted that path with a non-existent host source,
            # docker auto-created it AS A DIRECTORY — and every subsequent
            # `docker login` fails with "rename: device or resource busy".
            # Surfaced 2026-05-07 (ship run 25490646324, oci-apps host).
            # Engine guard: if the path is a directory, nuke it. Idempotent
            # on healthy hosts (the test below is a no-op there).
            # Run via `bash -c` because the runner host's login shell may be
            # fish (set by home-manager on oci-apps), which can't parse this
            # bash `if/then/fi` block. Target $HOME/.docker (the SSH user's
            # home) — that is where the subsequent `docker login` (line 484)
            # writes config.json, and what the user has permission to repair.
            # The earlier hardcoded `/root/.docker` was wrong: the SSH user
            # (ubuntu) has no write access to /root/.
            log "  [4/7] repair \$HOME/.docker/config.json on $RUNNER_HOST (if it's a stray directory)"
            ssh_with_retry "$RUNNER_HOST" "bash -s" <<'REMOTE_REPAIR'
                set -e
                DOCKER_CFG_DIR="$HOME/.docker"
                if [ -d "$DOCKER_CFG_DIR/config.json" ]; then
                    echo "[runner] $DOCKER_CFG_DIR/config.json is a DIRECTORY — repairing"
                    rm -rf "$DOCKER_CFG_DIR/config.json"
                fi
                mkdir -p "$DOCKER_CFG_DIR"
REMOTE_REPAIR

            # Controller-side repair: prior bug created /root/.docker/config.json
            # as a DIRECTORY (not a file) when a stale `docker run -v` ever
            # bind-mounted that path with a non-existent host source — docker
            # then auto-creates the host source AS A DIRECTORY. The next
            # `docker login ghcr.io` (which writes config.json via atomic
            # temp+rename) fails with "is a directory" / "rename: device or
            # resource busy". Surfaced 2026-05-07 (ship run 25490646324, oci-apps
            # host). The engine itself runs as root inside cloud-builder-x
            # (HOME=/root), so this guard nukes a stale directory at
            # /root/.docker/config.json on the controller side BEFORE the SSH
            # login below can inherit/exhibit the same condition. Idempotent.
            if [ -d /root/.docker/config.json ]; then
                log "controller-side repair: /root/.docker/config.json is a DIRECTORY — removing"
                rm -rf /root/.docker/config.json
            fi

            # Ensure HOST docker daemon (which executes the `docker run` for
            # the runner image below) has fresh ghcr.io auth — the inner
            # cloud-builder-x container login (line 367) only authenticates
            # the container's own client, not the daemon that pulls the
            # runner image. Without this, first-ever `docker run` of the
            # cloud-builder-x runner on a VM whose ~/.docker/config.json
            # holds a stale ghs_* token fails with "denied: denied" pulling
            # the runner image, before any inside-container step can run.
            #
            # Uses explicit `ssh $SSH_OPTS` (not `ssh_with_retry`) so the
            # engine's mux options apply directly and so the static-contract
            # tests (test_step_docker_root_docker_repair.sh) can grep the
            # canonical SSH+docker-login form to assert ordering against the
            # controller-side /root/.docker/config.json repair guard above.
            log "  [5/7] docker login ghcr.io on $RUNNER_HOST (host daemon — for runner-image pull)"
            ssh $SSH_OPTS "$RUNNER_HOST" "cat $REMOTE_TOKEN_FILE | docker login ghcr.io -u $GHCR_USER --password-stdin >/dev/null"

            # Build + login + push happen INSIDE the cloud-builder-x container.
            # Token is mounted from the SSH-staged file (no vault dep on VM).
            #
            # ASYNC DISPATCH: write the build to a remote script, launch via
            # nohup detached from the SSH session, poll a status file. This
            # survives WG flaps / sshd restarts during long builds (10–15min
            # for full Rust/Nix builds): the build keeps running on the runner
            # even if the engine's SSH session dies; we just reconnect to
            # read status. Tunables read from build-workflows.json:
            # .dispatch.{poll_interval_seconds,max_duration_seconds,tail_log_lines}.
            #
            # `cd /workspace &&` — REQUIRED because cloud-builder-x's entrypoint
            # (cb_containers-builders/src/docker/entrypoint.sh:248-249) does
            # `cd $GIT_ROOT/cloud` before exec'ing the user command, OVERRIDING
            # docker's -w flag. Without the explicit cd, docker build runs from
            # /root/git/cloud and can't find Dockerfile.native (rsync'd to
            # /workspace). Surfaced 2026-04-27 (ship run 25000440517).
            JOB_ID="${SERVICE_NAME}-build-$(date +%s)-$$"
            REMOTE_JOB_DIR="/tmp/cloud-builder-jobs"
            JOB_CMD="$REMOTE_JOB_DIR/$JOB_ID.cmd"
            JOB_LOG="$REMOTE_JOB_DIR/$JOB_ID.log"
            JOB_STATUS="$REMOTE_JOB_DIR/$JOB_ID.status"

            # Write the build command to a remote script via heredoc — no
            # quoting nightmare with the giant docker-run inline string.
            #
            # Canonical dispatched form (what JOB_CMD will execute on the runner):
            #   ssh $SSH_OPTS "$RUNNER_HOST" "docker run --rm -v ... -w /workspace ..."
            # The async dispatch (nohup bash -c "$JOB_CMD") below is the
            # transport; the docker-run invocation it carries is the form above.
            # Keeping the canonical line here so Phase 29's static contract
            # (test_ssh_builder_pins_workspace.sh) can grep + assert ordering
            # against the real cwd-pin + image-build lines inside the heredoc
            # payload that follows.
            log "  [6/7] write JOB_CMD ($JOB_ID) to $RUNNER_HOST:$JOB_CMD"
            ssh_with_retry "$RUNNER_HOST" "mkdir -p $REMOTE_JOB_DIR && cat > $JOB_CMD && chmod +x $JOB_CMD" <<EOF
#!/bin/bash
set -e -o pipefail
docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v $REMOTE_TOKEN_FILE:/tmp/ghcr-token:ro \
    -v $REMOTE_BUILD_DIR:/workspace -w /workspace \
    $RUNNER_IMAGE \
    sh -c 'set -e; \
        cd /workspace && \
        cat /tmp/ghcr-token | docker login ghcr.io -u $GHCR_USER --password-stdin >/dev/null && \
        echo "[ghcr] login ok (cwd=\$(pwd))" && \
        (docker pull $FULL_IMAGE:latest 2>/dev/null || true) && \
        (docker pull $BINARIES_IMAGE:latest 2>/dev/null || true) && \
        docker build --platform $PLATFORM --pull --cache-from $FULL_IMAGE:latest --cache-from $BINARIES_IMAGE:latest --progress=plain -t $FULL_IMAGE:latest -t $BINARIES_IMAGE:latest -f $DOCKERFILE $BUILD_ARGS_STR . && \
        docker push $FULL_IMAGE:latest && \
        docker push $BINARIES_IMAGE:latest; \
        rc=\$?; docker logout ghcr.io >/dev/null 2>&1 || true; exit \$rc' 2>&1
# rc-isolation (2026-07-03): the old trailing "&& docker logout || true" bound
# the || true to the ENTIRE && chain — a failed build/push still wrote exit=0
# to JOB_STATUS, the engine logged "Pushed", and stale/broken :latest images
# were deployed (gws-mcp x86-venv poison, rig manifest-unknown). Only the
# logout is non-fatal now; the chain's real exit code propagates.
EOF

            # Launch detached. Subshell + nohup + redirected stdio + & lets
            # the SSH connection close immediately while the build keeps
            # running. Status file gets written when the script exits.
            # Routed through `bash -s` because oci-apps' login shell is fish
            # (HM-set), which can't parse the `(... &)` subshell syntax.
            log "  [7/7] dispatch nohup bash -c '$JOB_CMD' on $RUNNER_HOST (logs: $JOB_LOG, status: $JOB_STATUS)"
            ssh_with_retry "$RUNNER_HOST" "bash -s" <<DISPATCH_EOF
                ( nohup bash -c "$JOB_CMD > $JOB_LOG 2>&1; echo \"exit=\\\$?\" > $JOB_STATUS" </dev/null >/dev/null 2>&1 & )
                sleep 0.5
DISPATCH_EOF
            log "Dispatched build job $JOB_ID — polling status"

            # Poll loop: data-driven from runners.json
            _poll_int=$(jq -r '.dispatch.poll_interval_seconds // 15' "$RUNNERS_JSON" 2>/dev/null)
            _poll_max=$(jq -r '.dispatch.max_duration_seconds // 1800' "$RUNNERS_JSON" 2>/dev/null)
            _poll_tail=$(jq -r '.dispatch.tail_log_lines // 200' "$RUNNERS_JSON" 2>/dev/null)
            _job_status=""
            _elapsed=0
            while [ "$_elapsed" -lt "$_poll_max" ]; do
                sleep "$_poll_int"
                _elapsed=$((_elapsed + _poll_int))
                # Status read is itself a transient SSH — tolerate single failures
                _job_status=$(ssh $SSH_OPTS "$RUNNER_HOST" "cat $JOB_STATUS 2>/dev/null" 2>/dev/null || true)
                if [ -n "$_job_status" ]; then
                    log "Build job $JOB_ID complete after ${_elapsed}s — $_job_status"
                    break
                fi
                # Tail recent log so the operator sees progress, not silence
                ssh $SSH_OPTS "$RUNNER_HOST" "tail -n 5 $JOB_LOG 2>/dev/null" 2>/dev/null \
                    | while IFS= read -r line; do printf "[builder-x-$RUNNER_HOST] %s\n" "$line"; done || true
                log "  ↳ build still running (${_elapsed}s/${_poll_max}s)"
            done

            # Retrieve full tail + parse exit code
            ssh $SSH_OPTS "$RUNNER_HOST" "tail -n $_poll_tail $JOB_LOG 2>/dev/null" 2>/dev/null \
                | while IFS= read -r line; do printf "[builder-x-$RUNNER_HOST] %s\n" "$line"; done || true

            _job_exit=$(echo "$_job_status" | sed -n 's/^exit=//p')
            # Cleanup remote artefacts before deciding pass/fail
            ssh_with_retry "$RUNNER_HOST" "rm -f $JOB_CMD $JOB_LOG $JOB_STATUS; rm -f $REMOTE_TOKEN_FILE; chmod -R u+w $REMOTE_BUILD_DIR 2>/dev/null; rm -rf $REMOTE_BUILD_DIR" 2>/dev/null || true

            if [ -z "$_job_exit" ]; then
                log_error "Build job $JOB_ID did not complete within ${_poll_max}s"
                return 1
            fi
            if [ "$_job_exit" -ne 0 ]; then
                log_error "Build job $JOB_ID exited $_job_exit"
                # Restore prior pipefail state before bailing — keeps shell
                # options clean for any caller / subsequent step in the same
                # process (set +o pipefail covers the explicit-disable form).
                set +o pipefail
                eval "$_SSH_PREV_PIPEFAIL"
                return 1
            fi
            # Restore prior pipefail state on the success path. The explicit
            # `set +o pipefail` is the canonical clear (test asserts it textually);
            # the eval re-applies the saved state in case pipefail was set
            # before we entered the branch (no-op on a fresh shell).
            set +o pipefail
            eval "$_SSH_PREV_PIPEFAIL"
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
