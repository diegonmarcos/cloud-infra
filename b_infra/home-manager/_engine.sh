#!/bin/sh
# Universal Home Manager build engine
# Symlinked as build.sh in each VM directory
# All behavior driven by build.json — zero hardcoded VM names
set -e

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_NAME="$(basename "$SERVICE_DIR")"
SRC_DIR="$SERVICE_DIR/src"
DIST_DIR="$SERVICE_DIR/dist"
CONFIG="$SERVICE_DIR/build.json"

# ── Config reader (node primary, python3 fallback) ────────────────────
get_config() {
    [ ! -f "$CONFIG" ] && return 0
    if command -v node >/dev/null 2>&1; then
        node -e "const c=require('$CONFIG'); const v='$1'.split('.').reduce((o,k)=>o&&o[k],c); process.stdout.write(String(v||''))"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import json; c=json.load(open('$CONFIG')); v=$( echo "'$1'.split('.')" | sed "s/'/\"/g" ); r=c; exec('for k in v: r=r.get(k,{})'); print(r if isinstance(r,str) else '',end='')"
    fi
}

# ── Load config ───────────────────────────────────────────────────────
if [ -f "$CONFIG" ]; then
    DEPLOY_HOST="$(get_config deploy.host)"
    DEPLOY_PATH="$(get_config deploy.remote_path)"
    HM_CONFIG="$(get_config hm.config)"
fi

# Age key - auto-detect mobile vs desktop
if [ -f "$HOME/git/vault/A0_keys/providers/system/oauth/age_keys.txt" ]; then
    : "${SOPS_AGE_KEY_FILE:=$HOME/git/vault/A0_keys/providers/system/oauth/age_keys.txt}"
elif [ -f "/home/diego/Mounts/Git/vault/A0_keys/providers/system/oauth/age_keys.txt" ]; then
    : "${SOPS_AGE_KEY_FILE:=/home/diego/Mounts/Git/vault/A0_keys/providers/system/oauth/age_keys.txt}"
fi
export SOPS_AGE_KEY_FILE

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }

# ── Step: Build (prepare dist/ from src/) ─────────────────────────────
# HM has no local nix build — the VM builds. This step resolves symlinks
# to shared modules so dist/ is a self-contained deploy payload.
step_build() {
    log "Preparing dist/ from src/"
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"
    # Copy src/ resolving symlinks (shared modules become real files)
    cp -rL "$SRC_DIR/"* "$DIST_DIR/"
    chmod -R u+w "$DIST_DIR"
    log "Built files:"
    find "$DIST_DIR" -type f | sed "s|$DIST_DIR/|  |"
}

# ── Step: Decrypt secrets ─────────────────────────────────────────────
step_secrets() {
    secrets_file="$SRC_DIR/secrets.yaml"

    if [ ! -f "$secrets_file" ]; then
        log "No secrets.yaml — skipping"
        return 0
    fi

    log "Decrypting secrets -> dist/.secrets"
    mkdir -p "$DIST_DIR"

    if command -v yq >/dev/null 2>&1; then
        sops -d "$secrets_file" | yq -r 'to_entries | .[] | "\(.key)=\(.value)"' \
            | grep '^[A-Z_]*=' > "$DIST_DIR/.secrets"
    elif command -v python3 >/dev/null 2>&1; then
        sops -d "$secrets_file" | python3 -c "
import sys
for line in sys.stdin:
    line = line.strip()
    if line.startswith('sops:'):
        break
    if not line or line.startswith('#'):
        continue
    if ':' in line:
        k, v = line.split(':', 1)
        k, v = k.strip(), v.strip().strip('\"').strip(\"'\")
        if v:
            print(f'{k}={v}')
" > "$DIST_DIR/.secrets"
    else
        log "ERROR: No yq or python3 for YAML->env conversion"
        return 1
    fi

    log "Secrets decrypted ($(grep -c '=' "$DIST_DIR/.secrets" 2>/dev/null || echo 0) keys)"
}

# ── Step: Deploy dist/ to VM ──────────────────────────────────────────
step_deploy() {
    [ -z "$DEPLOY_HOST" ] && { log "No deploy.host — skipping deploy"; return 0; }
    [ ! -d "$DIST_DIR" ] && { log "No dist/ — run build first"; return 1; }

    REMOTE_PATH="${DEPLOY_PATH:-\~/.config/home-manager}"
    log "Deploying dist/ -> $DEPLOY_HOST:$REMOTE_PATH"

    ssh "$DEPLOY_HOST" "mkdir -p $REMOTE_PATH"

    if command -v rsync >/dev/null 2>&1; then
        rsync -avz --delete "$DIST_DIR/" "$DEPLOY_HOST:$REMOTE_PATH/" 2>&1 \
            | grep -v "^sending\|^sent\|^total" || true
    else
        scp -r "$DIST_DIR/"* "$DEPLOY_HOST:$REMOTE_PATH/"
        [ -f "$DIST_DIR/.secrets" ] && scp "$DIST_DIR/.secrets" "$DEPLOY_HOST:$REMOTE_PATH/"
    fi

    log "Deployed to $DEPLOY_HOST:$REMOTE_PATH"
}

# ── Step: Activate home-manager on VM ─────────────────────────────────
step_compose() {
    [ -z "$DEPLOY_HOST" ] && { log "No deploy.host — skipping compose"; return 0; }
    [ -z "$HM_CONFIG" ] && { log "ERROR: hm.config not set in build.json"; return 1; }

    REMOTE_PATH="${DEPLOY_PATH:-\~/.config/home-manager}"
    log "Activating home-manager on $DEPLOY_HOST ($HM_CONFIG)..."

    # Source nix for full PATH (non-interactive SSH doesn't load profiles)
    NIX_SOURCE=". /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null ||:"

    ssh "$DEPLOY_HOST" "$NIX_SOURCE; cd $REMOTE_PATH && nix run home-manager/release-24.11 -- switch --flake .#$HM_CONFIG -b backup" 2>&1 | tail -20

    log "Activated $HM_CONFIG on $DEPLOY_HOST"

    # Trim to last 3 generations and GC
    ssh "$DEPLOY_HOST" "$NIX_SOURCE; nix-env --delete-generations +3 && nix-collect-garbage" 2>&1 || true
    log "Generations trimmed on $DEPLOY_HOST"
}

# ── Main ──────────────────────────────────────────────────────────────
echo "========================================"
echo "  Home Manager: $SERVICE_NAME"
echo "========================================"

case "${1:-all}" in
    build)    step_build ;;
    secrets)  step_secrets ;;
    deploy)   step_deploy ;;
    compose)  step_compose ;;
    all)      step_build; step_secrets ;;
    ship)     step_build; step_secrets; step_deploy; step_compose ;;
    clean)    rm -rf "$DIST_DIR"; log "Cleaned" ;;
    *)
        echo "Usage: $0 [build|secrets|deploy|compose|all|ship|clean]"
        echo ""
        echo "Commands:"
        echo "  build     Prepare dist/ from src/ (resolve symlinks)"
        echo "  secrets   Decrypt secrets -> dist/.secrets"
        echo "  deploy    Rsync dist/ -> VM"
        echo "  compose   Activate home-manager on VM (nix run home-manager -- switch)"
        echo "  all       build + secrets (default)"
        echo "  ship      build + secrets + deploy + compose"
        echo "  clean     Remove dist/"
        ;;
esac

log "Done."
