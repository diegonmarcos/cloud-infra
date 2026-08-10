# Step: Build documentation from nix flake #docs output
# Sourced by cloud-ship-container-engine.sh — do not execute directly

step_docs() {
    CURRENT_STEP="docs"
    cd "$SRC_DIR"

    # Skip gracefully if flake doesn't expose a `docs` output (v2 services
    # typically omit mdBook generation — optional).
    if ! nix eval --impure ".#docs.drvPath" >/dev/null 2>&1 \
       && ! nix eval --impure ".#packages.x86_64-linux.docs.drvPath" >/dev/null 2>&1; then
        log "No .docs output in flake — skipping docs step (optional)"
        return 0
    fi

    log "Building documentation..."
    # cloud-builder's deps devShell. Was "$SERVICE_DIR/../../workflows/src/
    # cloud-builder" — a path that stopped existing when 1_workflows was
    # absorbed into 1_configs, so the -d guard below has been silently taking
    # the no-devShell fallback ever since. The flake now lives with the service.
    DEPS_FLAKE="${CLOUD_ROOT:?CLOUD_ROOT unset}/a_solutions/infra-bld_cloud-builder-x/src"
    if [ -d "$DEPS_FLAKE" ] && command -v nix >/dev/null 2>&1; then
        nix develop "$DEPS_FLAKE#" --command bash -c "cd '$SRC_DIR' && nix build --option eval-cache false .#docs --out-link '$SERVICE_DIR/.result-docs'"
    else
        nix build --option eval-cache false .#docs --out-link "$SERVICE_DIR/.result-docs"
    fi

    mkdir -p "$DIST_DIR/docs"
    cp -rL "$SERVICE_DIR/.result-docs/"* "$DIST_DIR/docs/"
    chmod -R u+w "$DIST_DIR/docs"
    rm -f "$SERVICE_DIR/.result-docs"

    log "Documentation built -> dist/docs/"
}
