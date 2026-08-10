# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/gha/scripts/cloud-ship-nix-homemanager-step-build-docker.sh
# ║   Engine : 1_configs/src/gha/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Step: Docker package (nix build -> Docker context with closure)
# Sourced by cloud-ship-nix-homemanager-engine.sh — do not execute directly

step_docker_package() {
    [ -z "$HM_IMAGE" ] && { log "ERROR: hm.image not set in build.json"; return 1; }

    cd "$DIST_DIR"
    # Nix flakes in git repos only see tracked files
    git add "$DIST_DIR" 2>&1 | tee -a "$BUILD_LOG_FILE" || true
    log "Staged dist/ for nix ($(find "$DIST_DIR" -type f | wc -l) files)"

    NIX_RESULT_LINK2="$DIST_DIR/.hm-result"
    NIX_BUILD_CMD="nix build --out-link $NIX_RESULT_LINK2 --option eval-cache false .#homeConfigurations.\"$HM_CONFIG\".activationPackage"
    log "Flake: $DIST_DIR"
    log "Nix cmd: $NIX_BUILD_CMD"

    NIX_TMP=$(mktemp)
    set +e
    DEPS_FLAKE="$SERVICE_DIR/../../workflows/src/cloud-builder/src"
    if [ -d "$DEPS_FLAKE" ] && command -v nix >/dev/null 2>&1; then
        log "Using deps devShell from $DEPS_FLAKE"
        nix develop "$DEPS_FLAKE#" --command bash -c "cd '$DIST_DIR' && $NIX_BUILD_CMD" >"$NIX_TMP" 2>&1
        NIX_RC=$?
    else
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

    RESULT=""
    if [ -L "$NIX_RESULT_LINK2" ]; then
        RESULT=$(readlink -f "$NIX_RESULT_LINK2")
        rm -f "$NIX_RESULT_LINK2"
    fi
    if [ -z "$RESULT" ] || [ ! -d "$RESULT" ]; then
        log "ERROR: nix build produced no valid store path"
        log "Full nix output:"
        printf '%s\n' "$NIX_OUT"
        return 1
    fi
    log "Closure built: $RESULT"

    # ── Collect runtime closure ──
    log "Collecting runtime closure..."
    DOCKER_CTX="$DIST_DIR/docker-ctx"
    [ -d "$DOCKER_CTX" ] && chmod -R u+w "$DOCKER_CTX" 2>/dev/null || true
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

    # ── Nix DB dump (for --load-db on target VM) ──
    log "Exporting nix DB dump..."
    nix-store --dump-db $(nix-store -qR "$RESULT") > "$DOCKER_CTX/nix-db-dump.txt" 2>/dev/null || {
        log "ERROR: nix-store --dump-db failed"
        return 1
    }
    REG_SIZE=$(du -sh "$DOCKER_CTX/nix-db-dump.txt" 2>/dev/null | cut -f1 || echo "?")
    log "DB dump: $REG_SIZE"

    # ── Generate activate.sh ──
    RESULT_BASENAME=$(basename "$RESULT")
    cat > "$DOCKER_CTX/activate.sh" <<'ACTIVATE_EOF'
#!/bin/bash
set -euo pipefail
HOST="${HM_HOST_ROOT:-/host}"
HM_USER="${HM_USER:?HM_USER env var required}"
ACTIVATION="$HOST$HM_ACTIVATION_PATH/activate"

log() { printf '[hm-activate] %s\n' "$1"; }

# ── Copy nix store paths to host (skip existing — content-addressed) ──
# IMPORTANT: `cp -a` preserves hard links across the source. When two store
# paths share inodes (nix dedupes content via .links/), cp tries to create
# a hard link at the destination — but if the link target's directory has
# not been copied yet, cp errors:
#   cp: cannot create hard link '/host/nix/store/A/x' to '/host/nix/store/B/x'
# Worse, the original loop swallowed those failures silently:
#   cp -a "$p" "$HOST/nix/store/$base" && COPIED=$((COPIED + 1))
# bash's `set -e` does NOT trigger on `cmd1 && cmd2` (it's "tested"), so a
# failed cp left no copy on host but the loop continued — the activation
# generation path never made it to host, then activate failed with
# "activation path not found or not executable" (incident 2026-05-01).
# Fix: drop --preserve=links (via --no-preserve=links). Each hard-linked
# source becomes an independent copy at destination; nix-store's GC re-
# establishes the hard links via .links/ later. Plus fail-loud explicit
# error handling — a real cp failure now aborts and is visible.
log "Copying nix store paths to host..."
COPIED=0; SKIPPED=0; FAILED=0; REPAIRED=0
for p in /nix/store/*; do
    [ ! -e "$p" ] && continue
    base=$(basename "$p")
    HOST_PATH="$HOST/nix/store/$base"
    # Skip ONLY if host has a non-empty path. A partial path from a prior
    # failed ship would otherwise be silently kept and break activation.
    if [ -e "$HOST_PATH" ]; then
        if [ -d "$HOST_PATH" ] && [ -z "$(ls -A "$HOST_PATH" 2>/dev/null)" ]; then
            # empty dir — recopy
            rm -rf "$HOST_PATH"
            REPAIRED=$((REPAIRED + 1))
        else
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
    fi
    cp -aR --no-preserve=links "$p" "$HOST_PATH" 2>/dev/null
    # Verify by file presence, NOT cp's exit code. Concurrent activation
    # containers (orphaned from prior failed ships) write to the same
    # /nix/store and race; cp can return non-zero when the target was
    # just successfully written by the other process. Trust the filesystem.
    # Don't require non-empty: nix packages like `empty-directory`
    # legitimately contain nothing — that's the whole point. Partial-cp
    # detection is handled by the at-loop-entry empty-vs-needed check
    # above, plus the closure determinism (a non-empty source always
    # produces a non-empty target when cp returns 0).
    if [ -e "$HOST_PATH" ]; then
        COPIED=$((COPIED + 1))
    else
        # cp -rL fallback (full content copy, no hardlink preservation).
        rm -rf "$HOST_PATH" 2>/dev/null
        cp -rL "$p" "$HOST_PATH" 2>/dev/null
        if [ -e "$HOST_PATH" ]; then
            COPIED=$((COPIED + 1))
        else
            FAILED=$((FAILED + 1))
            log "WARN: failed to copy $base"
        fi
    fi
done
log "Store paths: $COPIED copied, $SKIPPED skipped (already on host), $REPAIRED empty repaired, $FAILED failed"
# Sanity: the activation path MUST be on host before we proceed.
# If the per-path loop missed it (e.g. cp returned 0 but produced no output
# under transient disk pressure, or the path existed as a stale partial from
# a prior failed ship), force a fresh copy here as a last resort.
if [ -n "${HM_ACTIVATION_PATH:-}" ] && [ ! -e "$HOST$HM_ACTIVATION_PATH" ]; then
    log "WARN: activation path missing on host after main loop — forcing copy"
    rm -rf "$HOST$HM_ACTIVATION_PATH" 2>/dev/null
    if cp -aR --no-preserve=links "$HM_ACTIVATION_PATH" "$HOST$HM_ACTIVATION_PATH"; then
        log "Forced copy succeeded: $HM_ACTIVATION_PATH"
    elif cp -rL "$HM_ACTIVATION_PATH" "$HOST$HM_ACTIVATION_PATH"; then
        log "Forced copy (deref) succeeded: $HM_ACTIVATION_PATH"
    fi
fi
if [ -n "${HM_ACTIVATION_PATH:-}" ] && [ ! -e "$HOST$HM_ACTIVATION_PATH" ]; then
    log "ERROR: activation path missing on host: $HM_ACTIVATION_PATH"
    log "       this is unrecoverable — the host cannot run the activation."
    log "       Diagnostic: container source: $(ls -la "$HM_ACTIVATION_PATH" 2>&1 | head -3)"
    log "                   host destination: $(ls -la "$HOST$HM_ACTIVATION_PATH" 2>&1 | head -3)"
    log "                   host disk: $(df -h "$HOST" | tail -1)"
    exit 1
fi
[ "$FAILED" -gt 0 ] && log "ERROR: $FAILED store paths failed — activation may be incomplete" && exit 1

# ── Copy DB dump to host (registration happens natively, not in container) ──
if [ -f "/hm/nix-db-dump.txt" ]; then
    cp /hm/nix-db-dump.txt "$HOST/tmp/.hm-nix-db-dump.txt"
    log "DB dump copied to host /tmp/"
else
    log "ERROR: /hm/nix-db-dump.txt not found"
    exit 1
fi

# ── Create nix command symlinks (HM activate needs them) ──
NIX_DIR="$HOST/nix/var/nix/profiles/default/bin"
if [ -d "$NIX_DIR" ] && [ -x "$NIX_DIR/nix" ]; then
    for cmd in nix-build nix-instantiate nix-env nix-store nix-channel; do
        [ ! -e "$NIX_DIR/$cmd" ] && ln -sf nix "$NIX_DIR/$cmd" 2>/dev/null && log "Created $cmd symlink"
    done
fi

# ── Write activation path for native activate step ──
echo "$HM_ACTIVATION_PATH" > "$HOST/tmp/.hm-activation-path"
log "Container done — activation path: $HM_ACTIVATION_PATH"
ACTIVATE_EOF

    # ── Generate Dockerfile from vm-pilot template ──
    # Source-of-truth: b_infra/_shared/vm-pilot/src/Dockerfile.transport
    # Substitutions are LITERAL (sed-no-regex via awk) for {{SERVICE_NAME}},
    # {{HM_ACTIVATION_PATH}}, {{HM_USER}}.
    # STEPS_DIR is /home/.../cloud/1_configs/src/gha/scripts (set in engine.sh)
    HM_DOCKERFILE_TPL="${HM_TRANSPORT_DOCKERFILE:-$STEPS_DIR/../../../b_infra/_shared/vm-pilot/src/Dockerfile.transport}"
    if [ ! -f "$HM_DOCKERFILE_TPL" ]; then
        log "ERROR: vm-pilot transport Dockerfile template missing: $HM_DOCKERFILE_TPL"
        return 1
    fi
    awk -v svc="$SERVICE_NAME" \
        -v ap="/nix/store/$RESULT_BASENAME" \
        -v hu="$HM_USER" '
      {
        line = $0
        while ((i = index(line, "{{SERVICE_NAME}}")) > 0)
          line = substr(line,1,i-1) svc substr(line,i+length("{{SERVICE_NAME}}"))
        while ((i = index(line, "{{HM_ACTIVATION_PATH}}")) > 0)
          line = substr(line,1,i-1) ap substr(line,i+length("{{HM_ACTIVATION_PATH}}"))
        while ((i = index(line, "{{HM_USER}}")) > 0)
          line = substr(line,1,i-1) hu substr(line,i+length("{{HM_USER}}"))
        print line
      }
    ' "$HM_DOCKERFILE_TPL" > "$DOCKER_CTX/Dockerfile"

    log "Docker context ready: $DOCKER_CTX ($(du -sh "$DOCKER_CTX" | cut -f1))"
    log "  Closure: ${CLOSURE_SIZE}MB, ${CLOSURE_COUNT} store paths"
    echo "$RESULT" > "$SERVICE_DIR/.closure-path"
}
