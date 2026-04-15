# Step: Build (prepare dist/ from src/)
# Sourced by cloud-ship-nix-homemanager-engine.sh — do not execute directly

step_build() {
    step_pull_pilot
    log "Preparing dist/ from src/"
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"
    cp -rL "$SRC_DIR/"* "$DIST_DIR/"
    chmod -R u+w "$DIST_DIR"
    # Nix flakes ignore untracked files in git repos — stage dist/ so nix can see it
    git add "$DIST_DIR" 2>/dev/null || true
    log "Built files:"
    find "$DIST_DIR" -type f | while IFS= read -r f; do echo "  ${f#$DIST_DIR/}"; done
}
