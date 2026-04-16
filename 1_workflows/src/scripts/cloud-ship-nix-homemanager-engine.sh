#!/bin/sh
# ╔════════════════════════════════════════════════════════════════╗
# ║ Universal Home Manager build engine                           ║
# ║ Symlinked as build.sh in each VM directory                    ║
# ║ All behavior driven by build.json — zero hardcoded VM names   ║
# ║                                                               ║
# ║ Steps are sourced from cloud-ship-nix-homemanager-step-*.sh   ║
# ║ files.                                                        ║
# ╚════════════════════════════════════════════════════════════════╝
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
BUILD_LOG_FILE="$SERVICE_DIR/build.log"

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
    HM_DELIVERY="$(get_config hm.delivery)"
    HM_IMAGE="$(get_config hm.image)"
    HM_PLATFORM="$(get_config hm.platform)"
    HM_REMOTE_BUILDER="$(get_config hm.remote_builder)"
fi

# Age key — use dotfile symlink set up by vault/build.sh setup system
: "${SOPS_AGE_KEY_FILE:=$HOME/.config/sops/age/keys.txt}"
export SOPS_AGE_KEY_FILE

# ── Logging: console + persistent build.log ───────────────────────────
# Every run overwrites build.log with full verbose output.
# Console sees the same output in real-time.
: > "$BUILD_LOG_FILE"

log() {
    _msg="[$(date '+%H:%M:%S')] $1"
    printf '%s\n' "$_msg"
    printf '%s\n' "$_msg" >> "$BUILD_LOG_FILE"
}

# Log a command's stdout+stderr to both console and build.log
# Usage: run_logged <description> <command> [args...]
run_logged() {
    _desc="$1"; shift
    log "RUN: $_desc"
    log "CMD: $*"
    set +e
    "$@" 2>&1 | tee -a "$BUILD_LOG_FILE"
    _exit=${PIPESTATUS:-$?}
    set -e
    if [ "$_exit" -ne 0 ]; then
        log "FAILED (exit $_exit): $_desc"
        return "$_exit"
    fi
    log "OK: $_desc"
    return 0
}

NIX_SOURCE="export PATH=\$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:\$PATH; . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null ||:"
REMOTE_PATH="${DEPLOY_PATH:-\~/.config/home-manager}"

# ── Source step files ─────────────────────────────────────────────────
STEPS_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
. "$STEPS_DIR/cloud-ship-nix-homemanager-step-pull-pilot.sh"
. "$STEPS_DIR/cloud-ship-nix-homemanager-step-build-flake.sh"
. "$STEPS_DIR/cloud-ship-nix-homemanager-step-secrets-decrypt.sh"
. "$STEPS_DIR/cloud-ship-nix-homemanager-step-deploy-rsync.sh"
. "$STEPS_DIR/cloud-ship-nix-homemanager-step-deploy-activate.sh"
. "$STEPS_DIR/cloud-ship-nix-homemanager-step-build-docker.sh"
. "$STEPS_DIR/cloud-ship-nix-homemanager-step-deploy-push.sh"

# ── Main ──────────────────────────────────────────────────────────────
# NOTE: Docker activation (pull + run on VM) is handled by ship-hm.sh step 6,
# not the engine. ship-hm.sh has SSH context; the engine doesn't.
if [ "$HM_DELIVERY" = "docker" ]; then
    STRATEGY="docker image → GHCR → VM pulls"
elif [ "$REMOTE_BUILD" = "true" ]; then
    STRATEGY="remote build on VM"
else
    STRATEGY="local build + nix copy"
fi

log "========================================"
log "  Home Manager: $SERVICE_NAME"
log "  Strategy: $STRATEGY"
log "  Host: ${DEPLOY_HOST:-none}"
log "  HM config: ${HM_CONFIG:-none}"
log "  Image: ${HM_IMAGE:-none}"
log "  Log: $BUILD_LOG_FILE"
log "========================================"

case "${1:-all}" in
    build)           step_build ;;
    secrets)         step_secrets ;;
    deploy)          step_deploy ;;
    compose)         step_compose ;;
    docker-package)  step_build; step_secrets; step_docker_package ;;
    docker-push)     step_docker_push ;;
    all)             step_build; step_secrets ;;
    ship)
        if [ "$HM_DELIVERY" = "docker" ] && [ "$HM_REMOTE_BUILDER" != "true" ]; then
            # Docker delivery: build locally → package → push → activate on VM
            step_build; step_secrets; step_docker_package; step_docker_push; step_compose
        elif [ "$HM_DELIVERY" = "docker" ] && [ "$HM_REMOTE_BUILDER" = "true" ]; then
            # ARM: can't cross-compile nix on x86 — remote build + activate on VM
            log "Remote builder: falling back to deploy+compose (skip docker packaging)"
            step_build; step_secrets; step_deploy; step_compose
        else
            step_build; step_secrets; step_deploy; step_compose
        fi
        ;;
    clean)  rm -rf "$DIST_DIR" "$SERVICE_DIR/.closure-path"; log "Cleaned" ;;
    *)
        echo "Usage: $0 [build|secrets|deploy|compose|docker-package|docker-push|all|ship|clean]"
        echo ""
        echo "  build           Prepare dist/ from src/ (resolve symlinks)"
        echo "  secrets         Decrypt secrets -> dist/.secrets"
        echo "  deploy          Build + copy closure (local) or rsync flake (remote)"
        echo "  compose         Activate home-manager on VM"
        echo "  docker-package  Build nix closure → Docker context with closure"
        echo "  docker-push     Build Docker image + push to GHCR"
        echo "  all             build + secrets (default)"
        echo "  ship            Full pipeline (docker or legacy based on hm.delivery)"
        echo "  clean           Remove dist/"
        ;;
esac

log "Done."
