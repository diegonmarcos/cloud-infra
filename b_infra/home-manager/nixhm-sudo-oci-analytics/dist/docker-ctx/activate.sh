#!/bin/bash
set -euo pipefail
HOST="${HM_HOST_ROOT:-/host}"
HM_USER="${HM_USER:?HM_USER env var required}"
ACTIVATION="$HOST$HM_ACTIVATION_PATH/activate"

log() { printf '[hm-activate] %s\n' "$1"; }

# ── Copy nix store paths to host (skip existing — content-addressed) ──
log "Copying nix store paths to host..."
COPIED=0; SKIPPED=0
for p in /nix/store/*; do
    [ ! -e "$p" ] && continue
    base=$(basename "$p")
    if [ -e "$HOST/nix/store/$base" ]; then
        SKIPPED=$((SKIPPED + 1))
    else
        cp -a "$p" "$HOST/nix/store/$base" && COPIED=$((COPIED + 1))
    fi
done
log "Store paths: $COPIED copied, $SKIPPED skipped (already on host)"

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
