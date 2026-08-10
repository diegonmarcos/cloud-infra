# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/deploy/scripts/cloud-ship-nix-homemanager-step-pull-pilot.sh
# ║   Engine : 1_configs/src/deploy/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Step: Pull vm-pilot modules (resolve src/pilot symlink)
# Sourced by cloud-ship-nix-homemanager-engine.sh — do not execute directly

step_pull_pilot() {
    # vm-pilot modules are resolved via src/pilot symlink → ../vm-pilot/src/modules/
    # cp -rL in step_build resolves this symlink automatically
    # The vm-pilot GHCR image (ghcr.io/diegonmarcos/vm-pilot) is a versioned artifact
    # but not required for builds — the symlink handles both local and GHA (same repo)
    if [ -L "$SRC_DIR/pilot" ] && [ -d "$SRC_DIR/pilot" ]; then
        log "vm-pilot: OK (symlink resolves)"
    elif [ -d "$SRC_DIR/pilot" ]; then
        log "vm-pilot: OK (directory)"
    else
        log "vm-pilot: WARNING — src/pilot not found, modules may be missing"
    fi
}
