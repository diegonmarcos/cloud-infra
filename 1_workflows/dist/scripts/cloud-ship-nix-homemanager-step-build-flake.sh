# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_workflows/src/scripts/cloud-ship-nix-homemanager-step-build-flake.sh
# ║   Engine : 1_workflows/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Step: Build (prepare dist/ from src/)
# Sourced by cloud-ship-nix-homemanager-engine.sh — do not execute directly

step_build() {
    step_pull_pilot
    log "Preparing dist/ from src/"
    [ -d "$DIST_DIR" ] && chmod -R u+w "$DIST_DIR" 2>/dev/null || true
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"
    # Stamp every copied file with the GENERATED-FILE banner. The lib
    # dereferences symlinks internally (same as `cp -L`) via find/cp.
    "$INJECT_HEADER" tree "$SRC_DIR" "$DIST_DIR"
    chmod -R u+w "$DIST_DIR"
    # Nix flakes ignore untracked files in git repos — stage dist/ so nix can see it
    git add "$DIST_DIR" 2>/dev/null || true
    log "Built files:"
    find "$DIST_DIR" -type f | while IFS= read -r f; do echo "  ${f#$DIST_DIR/}"; done
}
