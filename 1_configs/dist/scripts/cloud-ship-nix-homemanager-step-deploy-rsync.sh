# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/scripts/cloud-ship-nix-homemanager-step-deploy-rsync.sh
# ║   Engine : 1_configs/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Step: Deploy (rsync flake or nix copy closure to VM)
# Sourced by cloud-ship-nix-homemanager-engine.sh — do not execute directly

step_deploy() {
    [ -z "$DEPLOY_HOST" ] && { log "No deploy.host — skipping deploy"; return 0; }
    [ ! -d "$DIST_DIR" ] && { log "No dist/ — run build first"; return 1; }

    if [ "$REMOTE_BUILD" = "true" ]; then
        # ── Remote build: rsync full flake to VM ──
        log "Deploying flake to $DEPLOY_HOST (remote build)"
        ssh "$DEPLOY_HOST" "bash -c 'mkdir -p $REMOTE_PATH'"
        if command -v rsync >/dev/null 2>&1; then
            # `--rsync-path="bash -c rsync"` was previously used but invoked
            # rsync with NO arguments on the remote side → silent partial copy.
            # Rely on remote PATH (nix profile) finding rsync directly.
            # P-filters (2026-07-03): never let --delete remove deployed
            # secrets the secrets step placed (2026-07-02 mass-wipe incident).
            rsync -avz --delete \
                --filter='P .secrets' \
                --filter='P .secrets.d' \
                --filter='P .secrets.json' \
                "$DIST_DIR/" "$DEPLOY_HOST:$REMOTE_PATH/" 2>&1 \
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
        git add "$DIST_DIR" 2>&1 | tee -a "$BUILD_LOG_FILE" || true
        log "Staged dist/ for nix ($(git -C "$DIST_DIR" ls-files "$DIST_DIR" 2>/dev/null | wc -l) files)"
        NIX_RESULT_LINK="$DIST_DIR/.hm-result"
        NIX_BUILD_CMD="nix build --out-link $NIX_RESULT_LINK --option eval-cache false .#homeConfigurations.\"$HM_CONFIG\".activationPackage"

        log "Flake: $DIST_DIR"
        log "Nix cmd: $NIX_BUILD_CMD"

        NIX_TMP=$(mktemp)
        DEPS_FLAKE="$SERVICE_DIR/../../workflows/src/cloud-builder/src"
        set +e
        cd "$DIST_DIR"
        if [ -d "$DEPS_FLAKE" ] && command -v nix >/dev/null 2>&1; then
            log "Using deps devShell from $DEPS_FLAKE (provides cached flake inputs)"
            nix develop "$DEPS_FLAKE#" --command bash -c "$NIX_BUILD_CMD" >"$NIX_TMP" 2>&1
            NIX_RC=$?
        else
            log "Direct nix build (no deps flake)"
            eval "$NIX_BUILD_CMD" >"$NIX_TMP" 2>&1
            NIX_RC=$?
        fi
        set -e
        NIX_OUT=$(cat "$NIX_TMP")
        cat "$NIX_TMP" >> "$BUILD_LOG_FILE"
        rm -f "$NIX_TMP"

        if [ "$NIX_RC" -ne 0 ]; then
            log "ERROR: nix build failed (exit $NIX_RC)"
            log "Full nix output:"
            printf '%s\n' "$NIX_OUT"
            return 1
        fi

        # Resolve store path from symlink (reliable, doesn't depend on stdout)
        RESULT=""
        if [ -L "$NIX_RESULT_LINK" ]; then
            RESULT=$(readlink -f "$NIX_RESULT_LINK")
            rm -f "$NIX_RESULT_LINK"
        fi

        if [ -z "$RESULT" ] || [ ! -d "$RESULT" ]; then
            log "ERROR: nix build produced no valid store path"
            log "Full nix output:"
            printf '%s\n' "$NIX_OUT"
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
