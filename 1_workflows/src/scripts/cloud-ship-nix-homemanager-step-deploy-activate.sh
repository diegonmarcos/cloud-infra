# Step: Activate home-manager on VM
# Sourced by cloud-ship-nix-homemanager-engine.sh — do not execute directly

step_compose() {
    [ -z "$DEPLOY_HOST" ] && { log "No deploy.host — skipping compose"; return 0; }
    [ -z "$HM_CONFIG" ] && { log "ERROR: hm.config not set in build.json"; return 1; }

    if [ "$HM_DELIVERY" = "docker" ] && [ "$HM_REMOTE_BUILDER" != "true" ]; then
        # ── Docker delivery: pull image on VM, run activation container ──
        [ -z "$HM_IMAGE" ] && { log "ERROR: hm.image not set"; return 1; }
        HM_USER_VAR="${HM_USER:-diego}"
        log "Docker delivery: activating $HM_IMAGE on $DEPLOY_HOST"
        set +e
        ssh "$DEPLOY_HOST" "bash -c '
            export PATH=\$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:\$PATH
            echo \"[hm-docker] Pulling $HM_IMAGE:latest\"
            docker pull $HM_IMAGE:latest 2>&1 | tail -3
            echo \"[hm-docker] Running activation container\"
            docker run --rm -v /:/host -e HM_HOST_ROOT=/host $HM_IMAGE:latest 2>&1
            echo \"[hm-docker] Activating generation\"
            ACTIVATE=\$(cat /tmp/.hm-activation-path 2>/dev/null)
            if [ -n \"\$ACTIVATE\" ] && [ -x \"/host\$ACTIVATE/activate\" ]; then
                rm -f /home/$HM_USER_VAR/.local/bin/docker 2>/dev/null
                sudo -u $HM_USER_VAR HOME=/home/$HM_USER_VAR USER=$HM_USER_VAR \$ACTIVATE/activate 2>&1
            else
                echo \"[hm-docker] ERROR: activation path not found: \$ACTIVATE\"
                exit 1
            fi
        '" 2>&1 | tee -a "$BUILD_LOG_FILE"
        COMPOSE_RC=${PIPESTATUS:-$?}
        set -e
        if [ "$COMPOSE_RC" -ne 0 ]; then
            log "FAILED (exit $COMPOSE_RC): Docker HM activate on $DEPLOY_HOST"
            return 1
        fi
        log "Docker HM activated on $DEPLOY_HOST"
        return 0
    elif [ "$REMOTE_BUILD" = "true" ]; then
        # ── Remote build: full nix run on VM ──
        log "Activating on $DEPLOY_HOST (remote build)"
        SWITCH_CMD="export PATH=\$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:\$PATH; . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null || true; for cmd in nix-build nix-instantiate nix-env nix-store nix-channel; do if ! command -v \$cmd >/dev/null 2>&1; then NIX_BIN=\$(dirname \$(command -v nix)); ln -sf nix \$NIX_BIN/\$cmd 2>/dev/null || sudo ln -sf nix \$NIX_BIN/\$cmd; fi; done; cd $REMOTE_PATH && nix run home-manager/release-24.11 -- switch --option eval-cache false --flake .#$HM_CONFIG -b backup"
        log "Remote cmd: $SWITCH_CMD"
        set +e
        ssh "$DEPLOY_HOST" "bash -c '$SWITCH_CMD'" 2>&1 | tee -a "$BUILD_LOG_FILE"
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
        ssh "$DEPLOY_HOST" "bash -c '$ACTIVATE_CMD'" 2>&1 | tee -a "$BUILD_LOG_FILE"
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
