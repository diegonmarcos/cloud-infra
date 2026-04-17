#!/bin/bash
set -euo pipefail
HOST="${HM_HOST_ROOT:-/host}"
HM_USER="${HM_USER:-ubuntu}"
HM_HOME="$HOST/home/$HM_USER"
ACTIVATION="$HOST$HM_ACTIVATION_PATH/activate"

log() { printf '[hm-activate] %s\n' "$1"; }

log "Copying nix store paths to host..."
cp -rn /nix/store/* "$HOST/nix/store/" 2>/dev/null || true

# Register nix paths in host's DB (so nix recognizes copied store paths)
log "Registering nix paths in host DB..."
NIX_STORE_BIN=""
for _p in \
    "$HOST/nix/var/nix/profiles/default/bin/nix-store" \
    "$HOST/home/*/nix-profile/bin/nix-store" \
    "$HOST/home/*/.nix-profile/bin/nix-store"; do
    # shellcheck disable=SC2086
    for _f in $_p; do
        [ -x "$_f" ] && NIX_STORE_BIN="$_f" && break 2
    done
done
if [ -n "$NIX_STORE_BIN" ]; then
    log "Using nix-store at $NIX_STORE_BIN"
    if [ -f "/hm/nix-register-validity.txt" ]; then
        # Lightweight: register-validity is just metadata (~100KB), no OOM risk
        "$NIX_STORE_BIN" --register-validity < /hm/nix-register-validity.txt 2>&1 | tail -5 || true
        log "Paths registered via --register-validity"
    elif [ -f "/hm/nix-closure.nar.gz" ]; then
        # Fallback: full NAR import (heavy — may OOM on 1GB VMs)
        log "Using NAR fallback ($(du -sh /hm/nix-closure.nar.gz | cut -f1))"
        gunzip -c /hm/nix-closure.nar.gz | "$NIX_STORE_BIN" --import 2>&1 | tail -5 || true
        log "Nix closure imported via NAR"
    else
        log "WARN: no registration data — paths copied but not registered"
    fi
else
    log "WARN: nix-store not found on host — paths copied but not registered"
fi

# Decrypt secrets using host's age key
if [ -f "/hm/secrets.yaml" ]; then
    AGE_KEY="$HM_HOME/.config/sops/age/keys.txt"
    if [ -f "$AGE_KEY" ] && command -v sops >/dev/null 2>&1; then
        log "Decrypting secrets..."
        mkdir -p "$HM_HOME/.config/home-manager/.secrets.d"
        SOPS_AGE_KEY_FILE="$AGE_KEY" sops -d /hm/secrets.yaml > /tmp/.hm-secrets-raw
        # Extract KEY=VALUE pairs
        if command -v yq >/dev/null 2>&1; then
            : > "$HM_HOME/.config/home-manager/.secrets"
            for key in $(yq -r 'keys | .[] | select(. != "sops")' /tmp/.hm-secrets-raw); do
                val=$(yq -r ".[\"$key\"]" /tmp/.hm-secrets-raw)
                printf '%s=%s\n' "$key" "$val" >> "$HM_HOME/.config/home-manager/.secrets"
                printf '%s\n' "$val" > "$HM_HOME/.config/home-manager/.secrets.d/$key"
                chmod 600 "$HM_HOME/.config/home-manager/.secrets.d/$key"
            done
            log "Secrets decrypted ($(wc -l < "$HM_HOME/.config/home-manager/.secrets") keys)"
        fi
        rm -f /tmp/.hm-secrets-raw
    else
        log "WARN: No age key or sops — skipping secrets"
    fi
fi

# Create nix-build/nix-instantiate symlinks (HM activate needs them)
# Find the nix binary directory on the host
NIX_DIR=""
for _p in \
    "$HOST/nix/var/nix/profiles/default/bin" \
    "$HOST/home/*/nix-profile/bin" \
    "$HOST/home/*/.nix-profile/bin"; do
    # shellcheck disable=SC2086
    for _f in $_p; do
        [ -x "$_f/nix" ] && NIX_DIR="$_f" && break 2
    done
done
if [ -n "$NIX_DIR" ]; then
    for cmd in nix-build nix-instantiate nix-env nix-store nix-channel; do
        [ ! -e "$NIX_DIR/$cmd" ] && ln -sf nix "$NIX_DIR/$cmd" 2>/dev/null && log "Created $cmd symlink in $NIX_DIR"
    done
fi

# Write activation path — ship-hm.sh runs activate natively via SSH
echo "$HM_ACTIVATION_PATH" > "$HOST/tmp/.hm-activation-path"
log "Container done — activation path: $HM_ACTIVATION_PATH"
