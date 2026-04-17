# Step: Activate home-manager on VM
# Sourced by cloud-ship-nix-homemanager-engine.sh — do not execute directly

# ── Docker socket API helpers ───────────────────────────────────────────
# When docker CLI is missing on the VM (e.g. nix GC'd docker-client),
# fall back to curl against the Docker Engine unix socket.
DOCKER_SOCK="/var/run/docker.sock"

# Build the remote script that runs on the VM via SSH.
# This script auto-detects docker CLI vs socket API and uses the right one.
_build_docker_activate_script() {
    cat <<'REMOTE_SCRIPT_EOF'
#!/bin/bash
set -euo pipefail
DOCKER_SOCK="/var/run/docker.sock"
IMAGE="@@IMAGE@@"
TAG="@@TAG@@"
HM_USER="@@HM_USER@@"
FULL_IMAGE="${IMAGE}:${TAG}"

export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"

# ── Pre-check: Docker daemon running? ──
if [ -S "$DOCKER_SOCK" ]; then
    echo "[hm-docker] Docker socket found"
elif command -v systemctl >/dev/null 2>&1; then
    echo "[hm-docker] Starting Docker daemon..."
    sudo systemctl start docker 2>/dev/null || true
    sleep 2
    if [ ! -S "$DOCKER_SOCK" ]; then
        echo "[hm-docker] ERROR: Docker daemon failed to start"
        exit 1
    fi
else
    echo "[hm-docker] ERROR: Docker socket not found at $DOCKER_SOCK"
    exit 1
fi

# ── Transport detection ──
if command -v docker >/dev/null 2>&1; then
    USE_CLI=true
    echo "[hm-docker] Transport: docker CLI"
else
    USE_CLI=false
    if command -v curl >/dev/null 2>&1; then
        echo "[hm-docker] Transport: socket API (docker CLI not found)"
    else
        echo "[hm-docker] ERROR: neither docker CLI nor curl+socket available"
        exit 1
    fi
fi

# ── Helper: docker API via socket ──
dock_api() {
    _method="$1"; _endpoint="$2"; shift 2
    curl -sf --unix-socket "$DOCKER_SOCK" -X "$_method" "http://localhost$_endpoint" "$@"
}

# ── Step 1: Pull image ──
echo "[hm-docker] Pulling $FULL_IMAGE"
if [ "$USE_CLI" = true ]; then
    docker pull "$FULL_IMAGE" 2>&1 | tail -3
else
    HTTP_CODE=$(curl -s --unix-socket "$DOCKER_SOCK" -o /tmp/.hm-pull-out -w '%{http_code}' \
        -X POST "http://localhost/images/create?fromImage=${IMAGE}&tag=${TAG}")
    if [ "$HTTP_CODE" -ge 400 ]; then
        echo "[hm-docker] Pull failed (HTTP $HTTP_CODE):"
        cat /tmp/.hm-pull-out 2>/dev/null
        rm -f /tmp/.hm-pull-out
        exit 1
    fi
    tail -3 /tmp/.hm-pull-out 2>/dev/null || true
    rm -f /tmp/.hm-pull-out
    echo "[hm-docker] Pull complete"
fi

# ── Step 2: Clean up any previous hm-activate container ──
CONTAINER_NAME="hm-activate-$$"
if [ "$USE_CLI" = true ]; then
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
else
    OLD_IDS=$(dock_api GET '/containers/json?all=true&filters={"name":["hm-activate"]}' 2>/dev/null \
        | grep -o '"Id":"[^"]*"' | sed 's/"Id":"//;s/"//' || true)
    for _cid in $OLD_IDS; do
        dock_api POST "/containers/$_cid/stop" 2>/dev/null || true
        dock_api DELETE "/containers/$_cid" 2>/dev/null || true
    done
fi

# ── Step 3: Run activation container ──
echo "[hm-docker] Running activation container"
if [ "$USE_CLI" = true ]; then
    docker run --rm --name "$CONTAINER_NAME" -v /:/host -e HM_HOST_ROOT=/host "$FULL_IMAGE" 2>&1
else
    CREATE_BODY="{
        \"Image\": \"${FULL_IMAGE}\",
        \"Env\": [\"HM_HOST_ROOT=/host\"],
        \"HostConfig\": {
            \"Binds\": [\"/:/host\"]
        }
    }"
    CREATE_RESP=$(dock_api POST "/containers/create?name=${CONTAINER_NAME}" \
        -H "Content-Type: application/json" -d "$CREATE_BODY" 2>&1)
    CID=$(printf '%s' "$CREATE_RESP" | grep -o '"Id":"[^"]*"' | head -1 | sed 's/"Id":"//;s/"//')
    if [ -z "$CID" ]; then
        echo "[hm-docker] ERROR: container create failed: $CREATE_RESP"
        exit 1
    fi
    echo "[hm-docker] Container created: ${CID:0:12}"

    dock_api POST "/containers/$CID/start" >/dev/null 2>&1
    echo "[hm-docker] Container started"

    WAIT_RESP=$(dock_api POST "/containers/$CID/wait" 2>&1 || true)
    WAIT_CODE=$(printf '%s' "$WAIT_RESP" | grep -o '"StatusCode":[0-9]*' | sed 's/"StatusCode"://')
    WAIT_CODE="${WAIT_CODE:-999}"

    echo "[hm-docker] Container logs:"
    curl -s --unix-socket "$DOCKER_SOCK" "http://localhost/containers/$CID/logs?stdout=true&stderr=true" \
        2>/dev/null | tr -d '\000-\010' || true

    dock_api DELETE "/containers/$CID?force=true" 2>/dev/null || true

    if [ "$WAIT_CODE" -ne 0 ]; then
        echo "[hm-docker] ERROR: activation container exited with code $WAIT_CODE"
        exit 1
    fi
fi

# ── Step 4: Register nix paths in host DB (native, not container) ──
echo "[hm-docker] Registering nix paths (native)..."
export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"
if [ -f /tmp/.hm-nix-db-dump.txt ]; then
    sudo nix-store --load-db < /tmp/.hm-nix-db-dump.txt 2>&1 | tail -5
    echo "[hm-docker] Paths registered via --load-db"
    sudo rm -f /tmp/.hm-nix-db-dump.txt
else
    echo "[hm-docker] WARN: no DB dump found — paths may not be registered"
fi

# ── Step 5: Activate generation ──
echo "[hm-docker] Activating generation"
ACTIVATE=$(cat /tmp/.hm-activation-path 2>/dev/null)
if [ -n "$ACTIVATE" ] && [ -x "$ACTIVATE/activate" ]; then
    rm -f "/home/$HM_USER/.local/bin/docker" 2>/dev/null
    sudo -u "$HM_USER" HOME="/home/$HM_USER" USER="$HM_USER" "$ACTIVATE/activate" 2>&1
    echo "[hm-docker] Generation activated successfully"
else
    echo "[hm-docker] ERROR: activation path not found or not executable: $ACTIVATE"
    exit 1
fi
REMOTE_SCRIPT_EOF
}

step_compose() {
    [ -z "$DEPLOY_HOST" ] && { log "No deploy.host — skipping compose"; return 0; }
    [ -z "$HM_CONFIG" ] && { log "ERROR: hm.config not set in build.json"; return 1; }

    if [ "$HM_DELIVERY" = "docker" ] && [ "$HM_REMOTE_BUILDER" != "true" ]; then
        # ── Docker delivery: pull image on VM, run activation container ──
        [ -z "$HM_IMAGE" ] && { log "ERROR: hm.image not set"; return 1; }
        log "Docker delivery: activating $HM_IMAGE on $DEPLOY_HOST"

        # Deploy pre-decrypted secrets to VM via SSH
        if [ -f "$DIST_DIR/.secrets" ]; then
            log "Deploying secrets to $DEPLOY_HOST"
            ssh_vm "mkdir -p ~/.config/home-manager/.secrets.d"
            scp $SSH_OPTS "$DIST_DIR/.secrets" "$DEPLOY_HOST:~/.config/home-manager/.secrets"
            if [ -d "$DIST_DIR/.secrets.d" ]; then
                scp $SSH_OPTS -r "$DIST_DIR/.secrets.d/"* "$DEPLOY_HOST:~/.config/home-manager/.secrets.d/" 2>/dev/null || true
            fi
            ssh_vm "chmod 600 ~/.config/home-manager/.secrets ~/.config/home-manager/.secrets.d/* 2>/dev/null || true"
            log "Secrets deployed"
        fi

        # Build the remote script with variables substituted
        REMOTE_SCRIPT=$(_build_docker_activate_script)
        REMOTE_SCRIPT=$(printf '%s' "$REMOTE_SCRIPT" | sed "s|@@IMAGE@@|$HM_IMAGE|g; s|@@TAG@@|latest|g; s|@@HM_USER@@|$HM_USER|g")

        set +e
        printf '%s' "$REMOTE_SCRIPT" | ssh $SSH_OPTS "$DEPLOY_HOST" "bash -s" 2>&1 | tee -a "$BUILD_LOG_FILE"
        COMPOSE_RC=${PIPESTATUS[1]}
        set -e
        if [ "$COMPOSE_RC" -ne 0 ]; then
            log "FAILED (exit $COMPOSE_RC): Docker HM activate on $DEPLOY_HOST"
            return 1
        fi
        log "Docker HM activated on $DEPLOY_HOST"

    elif [ "$REMOTE_BUILD" = "true" ]; then
        # ── Remote build: full nix run on VM ──
        log "Activating on $DEPLOY_HOST (remote build)"
        SWITCH_CMD="export PATH=\$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:\$PATH; . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null || true; for cmd in nix-build nix-instantiate nix-env nix-store nix-channel; do if ! command -v \$cmd >/dev/null 2>&1; then NIX_BIN=\$(dirname \$(command -v nix)); ln -sf nix \$NIX_BIN/\$cmd 2>/dev/null || sudo ln -sf nix \$NIX_BIN/\$cmd; fi; done; cd $REMOTE_PATH && nix run home-manager/release-24.11 -- switch --option eval-cache false --flake .#$HM_CONFIG -b backup"
        log "Remote cmd: $SWITCH_CMD"
        set +e
        ssh_vm "bash -c '$SWITCH_CMD'" 2>&1 | tee -a "$BUILD_LOG_FILE"
        SWITCH_RC=${PIPESTATUS[0]}
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
        ssh_vm "bash -c '$ACTIVATE_CMD'" 2>&1 | tee -a "$BUILD_LOG_FILE"
        ACTIVATE_RC=${PIPESTATUS[0]}
        set -e
        if [ "$ACTIVATE_RC" -ne 0 ]; then
            log "FAILED (exit $ACTIVATE_RC): HM activate on $DEPLOY_HOST"
            return 1
        fi
        rm -f "$SERVICE_DIR/.closure-path"
    fi

    log "Activated $HM_CONFIG on $DEPLOY_HOST"

    # ── Post-activation: profile health + cleanup ──
    set +e
    # Ensure nix default profile is healthy
    ssh_vm 'bash -c '\''
        PROFILE_DIR=/nix/var/nix/profiles/per-user/root
        DEFAULT=/nix/var/nix/profiles/default
        if [ -L "$DEFAULT" ] && [ -d "$PROFILE_DIR" ]; then
            CURRENT=$(readlink -f "$DEFAULT")
            if [ ! -x "$CURRENT/bin/nix-collect-garbage" ] 2>/dev/null; then
                echo "[hm] nix profile broken — nix-collect-garbage missing"
                for link in "$PROFILE_DIR"/profile-*-link; do
                    TARGET=$(readlink -f "$link" 2>/dev/null)
                    if [ -x "$TARGET/bin/nix-collect-garbage" ]; then
                        GOOD=$(basename "$link")
                        echo "[hm] Restoring default profile → $GOOD"
                        sudo ln -sfn "$GOOD" "$PROFILE_DIR/profile"
                        break
                    fi
                done
            fi
        fi
    '\''' 2>&1 | tee -a "$BUILD_LOG_FILE" || true

    # Trim to last 3 generations (bash -c for fish-shell VMs)
    ssh_vm 'bash -c "export PATH=\$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:\$PATH; nix-env --delete-generations +3 2>/dev/null || true"' 2>&1 | tee -a "$BUILD_LOG_FILE" || true
    # Only GC if >2GB free RAM
    ssh_vm 'bash -c "export PATH=\$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:\$PATH; MEM=\$(awk \"/MemAvailable/ {print int(\\\$2/1024)}\" /proc/meminfo); [ \"\$MEM\" -gt 2048 ] && nix-collect-garbage 2>/dev/null || echo \"[hm] Skipping GC (\${MEM}MB free < 2GB threshold)\""' 2>&1 | tee -a "$BUILD_LOG_FILE" || true
    set -e
    log "Generations trimmed on $DEPLOY_HOST"
}
