#!/bin/sh
# Universal Home Manager build engine
# Symlinked as build.sh in each VM directory
# All behavior driven by build.json — zero hardcoded VM names
#
# Build strategy (declared in build.json hm.remote_build):
#   false → nix build on runner → nix copy closure → activate on VM
#   true  → rsync flake to VM → build + activate on VM
set -e

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_NAME="$(basename "$SERVICE_DIR")"
SRC_DIR="$SERVICE_DIR/src"
DIST_DIR="$SERVICE_DIR/dist"
CONFIG="$SERVICE_DIR/build.json"
BUILD_LOG_FILE="$SERVICE_DIR/build.log"

# ── Config reader (node primary, python3 fallback) ────────────────────
get_config() {
    [ ! -f "$CONFIG" ] && return 0
    if command -v node >/dev/null 2>&1; then
        node -e "const c=require('$CONFIG'); const v='$1'.split('.').reduce((o,k)=>o&&o[k],c); process.stdout.write(String(v||''))"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import json; c=json.load(open('$CONFIG')); v=$( echo "'$1'.split('.')" | sed "s/'/\"/g" ); r=c; exec('for k in v: r=r.get(k,{})'); print(r if isinstance(r,str) else '',end='')"
    fi
}

# ── Load config ───────────────────────────────────────────────────────
if [ -f "$CONFIG" ]; then
    DEPLOY_HOST="$(get_config deploy.host)"
    DEPLOY_PATH="$(get_config deploy.remote_path)"
    HM_CONFIG="$(get_config hm.config)"
    REMOTE_BUILD="$(get_config hm.remote_build)"
    HM_DELIVERY="$(get_config hm.delivery)"
    HM_IMAGE="$(get_config hm.image)"
    HM_PLATFORM="$(get_config hm.platform)"
    HM_REMOTE_BUILDER="$(get_config hm.remote_builder)"
fi

# Age key — use dotfile symlink set up by vault/build.sh setup system
: "${SOPS_AGE_KEY_FILE:=$HOME/.config/sops/age/keys.txt}"
export SOPS_AGE_KEY_FILE

# ── Logging: console + persistent build.log ───────────────────────────
# Every run overwrites build.log with full verbose output.
# Console sees the same output in real-time.
: > "$BUILD_LOG_FILE"

log() {
    _msg="[$(date '+%H:%M:%S')] $1"
    printf '%s\n' "$_msg"
    printf '%s\n' "$_msg" >> "$BUILD_LOG_FILE"
}

# Log a command's stdout+stderr to both console and build.log
# Usage: run_logged <description> <command> [args...]
run_logged() {
    _desc="$1"; shift
    log "RUN: $_desc"
    log "CMD: $*"
    set +e
    "$@" 2>&1 | tee -a "$BUILD_LOG_FILE"
    _exit=${PIPESTATUS:-$?}
    set -e
    if [ "$_exit" -ne 0 ]; then
        log "FAILED (exit $_exit): $_desc"
        return "$_exit"
    fi
    log "OK: $_desc"
    return 0
}

NIX_SOURCE="export PATH=\$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:\$PATH; . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null ||:"
REMOTE_PATH="${DEPLOY_PATH:-\~/.config/home-manager}"

# ── Step: Build (prepare dist/ from src/) ─────────────────────────────
step_build() {
    log "Preparing dist/ from src/"
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"
    cp -rL "$SRC_DIR/"* "$DIST_DIR/"
    chmod -R u+w "$DIST_DIR"
    # Nix flakes ignore untracked files in git repos — stage dist/ so nix can see it
    git add --force "$DIST_DIR" 2>/dev/null || true
    log "Built files:"
    find "$DIST_DIR" -type f | sed "s|$DIST_DIR/|  |"
}

# ── Step: Decrypt secrets ─────────────────────────────────────────────
step_secrets() {
    secrets_file="$SRC_DIR/secrets.yaml"

    if [ ! -f "$secrets_file" ]; then
        log "No secrets.yaml — skipping"
        return 0
    fi

    log "Decrypting secrets -> dist/.secrets + .secrets.d/"
    mkdir -p "$DIST_DIR/.secrets.d"

    if ! command -v yq >/dev/null 2>&1; then
        log "ERROR: yq required for YAML->env conversion"
        return 1
    fi

    # Decrypt → write ALL keys to both:
    #   .secrets     = KEY=VALUE lines (docker-compose env_file)
    #   .secrets.d/  = one raw file per key (ssh-keys.nix, file mounts)
    DECRYPTED=$(sops -d "$secrets_file")
    KEY_COUNT=0
    : > "$DIST_DIR/.secrets"

    for key in $(printf '%s' "$DECRYPTED" | yq -r 'keys | .[] | select(. != "sops")'); do
        val=$(printf '%s' "$DECRYPTED" | yq -r ".[\"$key\"]")
        # .secrets.d/KEY — raw file
        printf '%s\n' "$val" > "$DIST_DIR/.secrets.d/$key"
        chmod 600 "$DIST_DIR/.secrets.d/$key"
        # .secrets — KEY=VALUE
        printf '%s=%s\n' "$key" "$val" >> "$DIST_DIR/.secrets"
        KEY_COUNT=$((KEY_COUNT + 1))
    done

    log "Secrets decrypted ($KEY_COUNT keys)"
}

# ── Step: Deploy ──────────────────────────────────────────────────────
step_deploy() {
    [ -z "$DEPLOY_HOST" ] && { log "No deploy.host — skipping deploy"; return 0; }
    [ ! -d "$DIST_DIR" ] && { log "No dist/ — run build first"; return 1; }

    if [ "$REMOTE_BUILD" = "true" ]; then
        # ── Remote build: rsync full flake to VM ──
        log "Deploying flake to $DEPLOY_HOST (remote build)"
        ssh "$DEPLOY_HOST" "mkdir -p $REMOTE_PATH"
        if command -v rsync >/dev/null 2>&1; then
            rsync -avz --delete "$DIST_DIR/" "$DEPLOY_HOST:$REMOTE_PATH/" 2>&1 \
                | grep -v "^sending\|^sent\|^total" || true
        else
            scp -r "$DIST_DIR/"* "$DEPLOY_HOST:$REMOTE_PATH/"
            [ -f "$DIST_DIR/.secrets" ] && scp "$DIST_DIR/.secrets" "$DEPLOY_HOST:$REMOTE_PATH/"
        fi
        log "Flake deployed to $DEPLOY_HOST:$REMOTE_PATH"
    else
        # ── Local build: nix build on runner → nix copy closure to VM ──
        log "Building HM closure locally for $HM_CONFIG"
        cd "$DIST_DIR"
        # Nix flakes in git repos only see tracked files — force-stage dist/
        git add --force "$DIST_DIR" 2>&1 | tee -a "$BUILD_LOG_FILE" || true
        log "Staged dist/ for nix ($(git -C "$DIST_DIR" ls-files "$DIST_DIR" 2>/dev/null | wc -l) files)"
        DEPS_FLAKE="$SERVICE_DIR/../../workflows/src/cloud-builder"
        NIX_BUILD_CMD="nix build --no-link --print-out-paths --option eval-cache false .#homeConfigurations.\"$HM_CONFIG\".activationPackage"

        log "Flake: $DIST_DIR"
        log "Nix cmd: $NIX_BUILD_CMD"

        NIX_OUT=""
        set +e
        if [ -d "$DEPS_FLAKE" ] && command -v nix >/dev/null 2>&1; then
            log "Using deps devShell from $DEPS_FLAKE"
            NIX_OUT=$(nix develop "$DEPS_FLAKE#" --command bash -c "cd '$DIST_DIR' && $NIX_BUILD_CMD" 2>&1 | tee -a "$BUILD_LOG_FILE")
            NIX_RC=${PIPESTATUS:-$?}
        else
            log "Using direct nix build (no deps flake)"
            NIX_OUT=$(eval "$NIX_BUILD_CMD" 2>&1 | tee -a "$BUILD_LOG_FILE")
            NIX_RC=${PIPESTATUS:-$?}
        fi
        set -e

        if [ "$NIX_RC" -ne 0 ]; then
            log "ERROR: nix build failed (exit $NIX_RC)"
            log "Full nix output:"
            printf '%s\n' "$NIX_OUT"
            return 1
        fi

        # Extract store path (last line of output)
        RESULT=$(printf '%s\n' "$NIX_OUT" | grep '^/nix/store/' | tail -1)

        if [ -z "$RESULT" ] || [ ! -d "$RESULT" ]; then
            log "ERROR: nix build produced no valid store path"
            log "Full nix output:"
            printf '%s\n' "$NIX_OUT"
            return 1
        fi
        log "Closure built: $RESULT"

        # Check VM free RAM before nix copy (avoid OOM on <2GB VMs)
        set +e
        VM_MEM=$(ssh "$DEPLOY_HOST" "awk '/MemAvailable/ {print int(\$2/1024)}' /proc/meminfo 2>/dev/null")
        set -e
        VM_MEM="${VM_MEM:-9999}"
        if [ "$VM_MEM" -lt 200 ]; then
            log "WARNING: VM has only ${VM_MEM}MB free — waiting 30s for earlyoom to free memory"
            sleep 30
            set +e
            VM_MEM=$(ssh "$DEPLOY_HOST" "awk '/MemAvailable/ {print int(\$2/1024)}' /proc/meminfo 2>/dev/null")
            set -e
            VM_MEM="${VM_MEM:-9999}"
            if [ "$VM_MEM" -lt 100 ]; then
                log "ERROR: VM has only ${VM_MEM}MB free — skipping nix copy (would OOM)"
                return 1
            fi
        fi
        log "Copying closure to $DEPLOY_HOST via nix copy (VM has ${VM_MEM}MB free)"
        run_logged "nix copy to $DEPLOY_HOST" nix copy --to "ssh://$DEPLOY_HOST" "$RESULT"
        log "Closure copied"

        # Save result path for compose step
        echo "$RESULT" > "$SERVICE_DIR/.closure-path"

        # Rsync secrets (not part of nix closure)
        ssh "$DEPLOY_HOST" "mkdir -p $REMOTE_PATH"
        if [ -f "$DIST_DIR/.secrets" ]; then
            run_logged "rsync secrets" rsync -az "$DIST_DIR/.secrets" "$DEPLOY_HOST:$REMOTE_PATH/.secrets"
        fi
        if [ -d "$DIST_DIR/.secrets.d" ]; then
            run_logged "rsync secrets.d" rsync -az "$DIST_DIR/.secrets.d/" "$DEPLOY_HOST:$REMOTE_PATH/.secrets.d/"
        fi
        log "Secrets synced"
    fi
}

# ── Step: Activate home-manager on VM ─────────────────────────────────
step_compose() {
    [ -z "$DEPLOY_HOST" ] && { log "No deploy.host — skipping compose"; return 0; }
    [ -z "$HM_CONFIG" ] && { log "ERROR: hm.config not set in build.json"; return 1; }

    if [ "$REMOTE_BUILD" = "true" ]; then
        # ── Remote build: full nix run on VM ──
        log "Activating on $DEPLOY_HOST (remote build)"
        SWITCH_CMD="export PATH=\$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:\$PATH; . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null || true; cd $REMOTE_PATH && nix run home-manager/release-24.11 -- switch --flake .#$HM_CONFIG -b backup"
        log "Remote cmd: $SWITCH_CMD"
        set +e
        ssh "$DEPLOY_HOST" "$SWITCH_CMD" 2>&1 | tee -a "$BUILD_LOG_FILE"
        SWITCH_RC=${PIPESTATUS:-$?}
        set -e
        if [ "$SWITCH_RC" -ne 0 ]; then
            log "FAILED (exit $SWITCH_RC): HM switch on $DEPLOY_HOST"
            return 1
        fi
    else
        # ── Local build: activate pre-built closure (no nix eval on VM) ──
        CLOSURE=$(cat "$SERVICE_DIR/.closure-path" 2>/dev/null || true)
        if [ -z "$CLOSURE" ]; then
            log "ERROR: no .closure-path — run deploy first"
            return 1
        fi
        log "Activating pre-built closure on $DEPLOY_HOST"
        ACTIVATE_CMD="export PATH=\$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:\$PATH; . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null || true; for cmd in nix-build nix-instantiate; do if ! command -v \$cmd >/dev/null 2>&1; then NIX_BIN=\$(dirname \$(command -v nix)); ln -sf nix \$NIX_BIN/\$cmd 2>/dev/null || sudo ln -sf nix \$NIX_BIN/\$cmd; fi; done; $CLOSURE/activate"
        log "Remote cmd: $ACTIVATE_CMD"
        set +e
        ssh "$DEPLOY_HOST" "$ACTIVATE_CMD" 2>&1 | tee -a "$BUILD_LOG_FILE"
        ACTIVATE_RC=${PIPESTATUS:-$?}
        set -e
        if [ "$ACTIVATE_RC" -ne 0 ]; then
            log "FAILED (exit $ACTIVATE_RC): HM activate on $DEPLOY_HOST"
            return 1
        fi
        rm -f "$SERVICE_DIR/.closure-path"
    fi

    log "Activated $HM_CONFIG on $DEPLOY_HOST"

    # Trim to last 3 generations (skip GC on resource-constrained VMs)
    set +e
    ssh "$DEPLOY_HOST" "$NIX_SOURCE; nix-env --delete-generations +3" 2>&1 | tee -a "$BUILD_LOG_FILE" || true
    # Only GC if >2GB free RAM (avoids OOM on 1GB VMs)
    ssh "$DEPLOY_HOST" 'MEM=$(awk "/MemAvailable/ {print int(\$2/1024)}" /proc/meminfo); [ "$MEM" -gt 2048 ] && nix-collect-garbage 2>/dev/null || echo "[hm] Skipping GC (${MEM}MB free < 2GB threshold)"' 2>&1 | tee -a "$BUILD_LOG_FILE" || true
    set -e
    log "Generations trimmed on $DEPLOY_HOST"
}

# ── Step: Docker package (nix build → Docker context with closure) ────
step_docker_package() {
    [ -z "$HM_IMAGE" ] && { log "ERROR: hm.image not set in build.json"; return 1; }

    cd "$DIST_DIR"
    # Nix flakes in git repos only see tracked files
    git add --force "$DIST_DIR" 2>&1 | tee -a "$BUILD_LOG_FILE" || true
    log "Staged dist/ for nix ($(find "$DIST_DIR" -type f | wc -l) files)"

    NIX_BUILD_CMD="nix build --no-link --print-out-paths --option eval-cache false .#homeConfigurations.\"$HM_CONFIG\".activationPackage"
    log "Flake: $DIST_DIR"
    log "Nix cmd: $NIX_BUILD_CMD"

    set +e
    DEPS_FLAKE="$SERVICE_DIR/../../workflows/src/cloud-builder"
    if [ -d "$DEPS_FLAKE" ] && command -v nix >/dev/null 2>&1; then
        log "Using deps devShell from $DEPS_FLAKE"
        NIX_OUT=$(nix develop "$DEPS_FLAKE#" --command bash -c "cd '$DIST_DIR' && $NIX_BUILD_CMD" 2>&1 | tee -a "$BUILD_LOG_FILE")
        NIX_RC=${PIPESTATUS:-$?}
    else
        NIX_OUT=$(eval "$NIX_BUILD_CMD" 2>&1 | tee -a "$BUILD_LOG_FILE")
        NIX_RC=${PIPESTATUS:-$?}
    fi
    set -e

    if [ "$NIX_RC" -ne 0 ]; then
        log "ERROR: nix build failed (exit $NIX_RC)"
        return 1
    fi

    RESULT=$(printf '%s\n' "$NIX_OUT" | grep '^/nix/store/' | tail -1)
    if [ -z "$RESULT" ] || [ ! -d "$RESULT" ]; then
        log "ERROR: nix build produced no valid store path"
        return 1
    fi
    log "Closure built: $RESULT"

    # Collect runtime closure (only store paths referenced at runtime)
    log "Collecting runtime closure..."
    DOCKER_CTX="$DIST_DIR/docker-ctx"
    chmod -R u+w "$DOCKER_CTX" 2>/dev/null || true
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

    # Export nix closure for import on VM (register paths in nix DB)
    log "Exporting nix closure registration..."
    nix-store --export $(nix-store -qR "$RESULT") 2>/dev/null | gzip > "$DOCKER_CTX/nix-closure.nar.gz" || {
        log "WARN: nix-store --export failed"
        rm -f "$DOCKER_CTX/nix-closure.nar.gz"
    }
    if [ -f "$DOCKER_CTX/nix-closure.nar.gz" ]; then
        NAR_SIZE=$(du -sh "$DOCKER_CTX/nix-closure.nar.gz" | cut -f1)
        log "NAR export: $NAR_SIZE (compressed)"
    fi

    # Copy encrypted secrets if present
    [ -f "$SRC_DIR/secrets.yaml" ] && cp "$SRC_DIR/secrets.yaml" "$DOCKER_CTX/"

    # Generate activate.sh
    RESULT_BASENAME=$(basename "$RESULT")
    HM_USER="$(get_config hm.user)"
    cat > "$DOCKER_CTX/activate.sh" <<'ACTIVATE_EOF'
#!/bin/bash
set -euo pipefail
HOST="${HM_HOST_ROOT:-/host}"
HM_USER="${HM_USER:-ubuntu}"
HM_HOME="$HOST/home/$HM_USER"
ACTIVATION="$HOST$HM_ACTIVATION_PATH/activate"

log() { printf '[hm-activate] %s\n' "$1"; }

log "Copying nix store paths to host..."
cp -rn /nix/store/* "$HOST/nix/store/" 2>/dev/null || true

# Import nix closure into host's nix DB (so nix-build recognizes paths)
log "Importing nix closure into host DB..."
if [ -f "/hm/nix-closure.nar.gz" ]; then
    log "NAR file found ($(du -sh /hm/nix-closure.nar.gz | cut -f1))"
    # Decompress and import via chroot (uses host's nix-store binary)
    gunzip -c /hm/nix-closure.nar.gz | chroot "$HOST" /bin/bash -c "
        export PATH=/nix/var/nix/profiles/default/bin:\$PATH
        nix-store --import
    " 2>&1 | tail -5
    log "Nix closure imported"
else
    log "WARN: /hm/nix-closure.nar.gz not found — activation may fail"
    ls -la /hm/ 2>/dev/null
fi

# Decrypt secrets using host's age key
if [ -f "/hm/secrets.yaml" ]; then
    AGE_KEY="$HM_HOME/.config/sops/age/keys.txt"
    if [ -f "$AGE_KEY" ] && command -v sops >/dev/null 2>&1; then
        log "Decrypting secrets..."
        mkdir -p "$HM_HOME/.config/home-manager/.secrets.d"
        SOPS_AGE_KEY_FILE="$AGE_KEY" sops -d /hm/secrets.yaml > /tmp/.hm-secrets-raw
        # Extract KEY=VALUE pairs
        if command -v yq >/dev/null 2>&1; then
            : > "$HM_HOME/.config/home-manager/.secrets"
            for key in $(yq -r 'keys | .[] | select(. != "sops")' /tmp/.hm-secrets-raw); do
                val=$(yq -r ".[\"$key\"]" /tmp/.hm-secrets-raw)
                printf '%s=%s\n' "$key" "$val" >> "$HM_HOME/.config/home-manager/.secrets"
                printf '%s\n' "$val" > "$HM_HOME/.config/home-manager/.secrets.d/$key"
                chmod 600 "$HM_HOME/.config/home-manager/.secrets.d/$key"
            done
            log "Secrets decrypted ($(wc -l < "$HM_HOME/.config/home-manager/.secrets") keys)"
        fi
        rm -f /tmp/.hm-secrets-raw
    else
        log "WARN: No age key or sops — skipping secrets"
    fi
fi

# Ensure nix-build/nix-instantiate symlinks exist (HM activate expects them)
NIX_PROFILE_BIN="$HOST/nix/var/nix/profiles/default/bin"
for cmd in nix-build nix-instantiate nix-env nix-store nix-channel; do
    if [ -x "$NIX_PROFILE_BIN/nix" ] && [ ! -e "$NIX_PROFILE_BIN/$cmd" ]; then
        ln -sf nix "$NIX_PROFILE_BIN/$cmd" 2>/dev/null || true
        log "Created symlink: $cmd -> nix"
    fi
done

# Run HM activation via chroot
log "Activating $HM_ACTIVATION_PATH..."
chroot "$HOST" /bin/bash -c "
    export HOME=/home/$HM_USER
    export USER=$HM_USER
    export PATH=/nix/var/nix/profiles/default/bin:\$HOME/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null || true
    $HM_ACTIVATION_PATH/activate
"
log "Activation complete"
ACTIVATE_EOF

    # Generate Dockerfile
    SECRETS_COPY=""
    [ -f "$DOCKER_CTX/secrets.yaml" ] && SECRETS_COPY="COPY secrets.yaml /hm/secrets.yaml"
    NAR_COPY=""
    [ -f "$DOCKER_CTX/nix-closure.nar.gz" ] && NAR_COPY="COPY nix-closure.nar.gz /hm/nix-closure.nar.gz"
    cat > "$DOCKER_CTX/Dockerfile" <<DOCKERFILE_EOF
FROM debian:bookworm-slim
LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
LABEL org.opencontainers.image.description="Home-Manager activation image for $SERVICE_NAME"
RUN apt-get update && apt-get install -y --no-install-recommends bash coreutils sudo gzip && rm -rf /var/lib/apt/lists/*
COPY nix-store/ /nix/store/
COPY activate.sh /hm/activate.sh
$SECRETS_COPY
$NAR_COPY
RUN chmod +x /hm/activate.sh
ENV HM_ACTIVATION_PATH=/nix/store/$RESULT_BASENAME
ENV HM_USER=$HM_USER
ENTRYPOINT ["/bin/bash", "/hm/activate.sh"]
DOCKERFILE_EOF

    log "Docker context ready: $DOCKER_CTX ($(du -sh "$DOCKER_CTX" | cut -f1))"
    log "  Closure: ${CLOSURE_SIZE}MB, ${CLOSURE_COUNT} store paths"
    echo "$RESULT" > "$SERVICE_DIR/.closure-path"
}

# ── Step: Docker push (build image + push to GHCR) ───────────────────
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

# ── Main ──────────────────────────────────────────────────────────────
if [ "$HM_DELIVERY" = "docker" ]; then
    STRATEGY="docker image → GHCR → VM pulls"
elif [ "$REMOTE_BUILD" = "true" ]; then
    STRATEGY="remote build on VM"
else
    STRATEGY="local build + nix copy"
fi

log "========================================"
log "  Home Manager: $SERVICE_NAME"
log "  Strategy: $STRATEGY"
log "  Host: ${DEPLOY_HOST:-none}"
log "  HM config: ${HM_CONFIG:-none}"
log "  Image: ${HM_IMAGE:-none}"
log "  Log: $BUILD_LOG_FILE"
log "========================================"

case "${1:-all}" in
    build)           step_build ;;
    secrets)         step_secrets ;;
    deploy)          step_deploy ;;
    compose)         step_compose ;;
    docker-package)  step_build; step_secrets; step_docker_package ;;
    docker-push)     step_docker_push ;;
    all)             step_build; step_secrets ;;
    ship)
        if [ "$HM_DELIVERY" = "docker" ]; then
            step_build; step_secrets; step_docker_package; step_docker_push
        else
            step_build; step_secrets; step_deploy; step_compose
        fi
        ;;
    clean)  rm -rf "$DIST_DIR" "$SERVICE_DIR/.closure-path"; log "Cleaned" ;;
    *)
        echo "Usage: $0 [build|secrets|deploy|compose|docker-package|docker-push|all|ship|clean]"
        echo ""
        echo "  build           Prepare dist/ from src/ (resolve symlinks)"
        echo "  secrets         Decrypt secrets -> dist/.secrets"
        echo "  deploy          Build + copy closure (local) or rsync flake (remote)"
        echo "  compose         Activate home-manager on VM"
        echo "  docker-package  Build nix closure → Docker context with closure"
        echo "  docker-push     Build Docker image + push to GHCR"
        echo "  all             build + secrets (default)"
        echo "  ship            Full pipeline (docker or legacy based on hm.delivery)"
        echo "  clean           Remove dist/"
        ;;
esac

log "Done."
