#!/bin/sh
# Universal Home Manager build engine
# Symlinked as build.sh in each VM directory
# All behavior driven by build.json — zero hardcoded VM names
#
# Build strategy (declared in build.json hm.remote_build):
#   false → nix build on runner → nix copy closure → activate on VM
#   true  → rsync flake to VM → build + activate on VM
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
    REMOTE_BUILD="$(get_config hm.remote_build)"
fi

# Age key - auto-detect mobile vs desktop
if [ -f "$HOME/git/vault/A0_keys/providers/system/oauth/age_keys.txt" ]; then
    : "${SOPS_AGE_KEY_FILE:=$HOME/git/vault/A0_keys/providers/system/oauth/age_keys.txt}"
elif [ -f "/home/diego/Mounts/Git/vault/A0_keys/providers/system/oauth/age_keys.txt" ]; then
    : "${SOPS_AGE_KEY_FILE:=/home/diego/Mounts/Git/vault/A0_keys/providers/system/oauth/age_keys.txt}"
fi
export SOPS_AGE_KEY_FILE

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }

NIX_SOURCE=". /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null ||:"
REMOTE_PATH="${DEPLOY_PATH:-\~/.config/home-manager}"

# ── Step: Build (prepare dist/ from src/) ─────────────────────────────
step_build() {
    log "Preparing dist/ from src/"
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"
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

# ── Step: Deploy ──────────────────────────────────────────────────────
step_deploy() {
    [ -z "$DEPLOY_HOST" ] && { log "No deploy.host — skipping deploy"; return 0; }
    [ ! -d "$DIST_DIR" ] && { log "No dist/ — run build first"; return 1; }

    if [ "$REMOTE_BUILD" = "true" ]; then
        # ── Remote build: rsync full flake to VM ──
        log "Deploying flake to $DEPLOY_HOST (remote build)"
        ssh "$DEPLOY_HOST" "mkdir -p $REMOTE_PATH"
        if command -v rsync >/dev/null 2>&1; then
            rsync -avz --delete "$DIST_DIR/" "$DEPLOY_HOST:$REMOTE_PATH/" 2>&1 \
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
        RESULT=$(nix build \
            --no-link --print-out-paths \
            ".#homeConfigurations.\"$HM_CONFIG\".activationPackage" 2>&1 | tail -1)

        if [ -z "$RESULT" ] || [ ! -d "$RESULT" ]; then
            log "ERROR: nix build failed"
            return 1
        fi
        log "Closure built: $RESULT"

        log "Copying closure to $DEPLOY_HOST via nix copy"
        nix copy --to "ssh://$DEPLOY_HOST" "$RESULT"
        log "Closure copied"

        # Save result path for compose step
        echo "$RESULT" > "$SERVICE_DIR/.closure-path"

        # Rsync secrets (not part of nix closure)
        ssh "$DEPLOY_HOST" "mkdir -p $REMOTE_PATH"
        if [ -f "$DIST_DIR/.secrets" ]; then
            rsync -az "$DIST_DIR/.secrets" "$DEPLOY_HOST:$REMOTE_PATH/.secrets"
            log "Secrets synced"
        fi
    fi
}

# ── Step: Activate home-manager on VM ─────────────────────────────────
step_compose() {
    [ -z "$DEPLOY_HOST" ] && { log "No deploy.host — skipping compose"; return 0; }
    [ -z "$HM_CONFIG" ] && { log "ERROR: hm.config not set in build.json"; return 1; }

    if [ "$REMOTE_BUILD" = "true" ]; then
        # ── Remote build: full nix run on VM ──
        log "Activating on $DEPLOY_HOST (remote build)"
        ssh "$DEPLOY_HOST" "$NIX_SOURCE; cd $REMOTE_PATH && nix run home-manager/release-24.11 -- switch --flake .#$HM_CONFIG -b backup" 2>&1 | tail -20
    else
        # ── Local build: activate pre-built closure (no nix eval on VM) ──
        CLOSURE=$(cat "$SERVICE_DIR/.closure-path" 2>/dev/null || true)
        if [ -z "$CLOSURE" ]; then
            log "ERROR: no .closure-path — run deploy first"
            return 1
        fi
        log "Activating pre-built closure on $DEPLOY_HOST"
        ssh "$DEPLOY_HOST" "$NIX_SOURCE; $CLOSURE/activate" 2>&1 | tail -20
        rm -f "$SERVICE_DIR/.closure-path"
    fi

    log "Activated $HM_CONFIG on $DEPLOY_HOST"

    # Trim to last 3 generations and GC
    ssh "$DEPLOY_HOST" "$NIX_SOURCE; nix-env --delete-generations +3 && nix-collect-garbage" 2>&1 || true
    log "Generations trimmed on $DEPLOY_HOST"
}

# ── Main ──────────────────────────────────────────────────────────────
STRATEGY="local build + nix copy"
[ "$REMOTE_BUILD" = "true" ] && STRATEGY="remote build on VM"

echo "========================================"
echo "  Home Manager: $SERVICE_NAME"
echo "  Strategy: $STRATEGY"
echo "========================================"

case "${1:-all}" in
    build)    step_build ;;
    secrets)  step_secrets ;;
    deploy)   step_deploy ;;
    compose)  step_compose ;;
    all)      step_build; step_secrets ;;
    ship)     step_build; step_secrets; step_deploy; step_compose ;;
    clean)    rm -rf "$DIST_DIR" "$SERVICE_DIR/.closure-path"; log "Cleaned" ;;
    *)
        echo "Usage: $0 [build|secrets|deploy|compose|all|ship|clean]"
        echo ""
        echo "  build     Prepare dist/ from src/ (resolve symlinks)"
        echo "  secrets   Decrypt secrets -> dist/.secrets"
        echo "  deploy    Build + copy closure (local) or rsync flake (remote)"
        echo "  compose   Activate home-manager on VM"
        echo "  all       build + secrets (default)"
        echo "  ship      build + secrets + deploy + compose"
        echo "  clean     Remove dist/"
        ;;
esac

log "Done."
