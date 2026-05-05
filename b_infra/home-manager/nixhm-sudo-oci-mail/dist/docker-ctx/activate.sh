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
COPIED=0; SKIPPED=0; FAILED=0
for p in /nix/store/*; do
    [ ! -e "$p" ] && continue
    base=$(basename "$p")
    if [ -e "$HOST/nix/store/$base" ]; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    if cp -aR --no-preserve=links "$p" "$HOST/nix/store/$base" 2>/dev/null; then
        COPIED=$((COPIED + 1))
    else
        # Retry without any link preservation — full content copy.
        rm -rf "$HOST/nix/store/$base" 2>/dev/null
        if cp -rL "$p" "$HOST/nix/store/$base" 2>/dev/null; then
            COPIED=$((COPIED + 1))
        else
            FAILED=$((FAILED + 1))
            log "WARN: failed to copy $base"
        fi
    fi
done
log "Store paths: $COPIED copied, $SKIPPED skipped (already on host), $FAILED failed"
# Sanity: the activation path MUST be on host before we proceed.
if [ -n "${HM_ACTIVATION_PATH:-}" ] && [ ! -e "$HOST$HM_ACTIVATION_PATH" ]; then
    log "ERROR: activation path missing on host: $HM_ACTIVATION_PATH"
    log "       this is unrecoverable — the host cannot run the activation."
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
