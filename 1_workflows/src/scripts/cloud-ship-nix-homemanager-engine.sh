#!/usr/bin/env bash
# ╔════════════════════════════════════════════════════════════════╗
# ║ Universal Home Manager build engine                           ║
# ║ Symlinked as build.sh in each VM directory                    ║
# ║ All behavior driven by build.json — zero hardcoded VM names   ║
# ║                                                               ║
# ║ Steps are sourced from cloud-ship-nix-homemanager-step-*.sh   ║
# ╚════════════════════════════════════════════════════════════════╝
set -euo pipefail

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_NAME="$(basename "$SERVICE_DIR")"
SRC_DIR="$SERVICE_DIR/src"
DIST_DIR="$SERVICE_DIR/dist"
CONFIG="$SERVICE_DIR/build.json"
BUILD_LOG_FILE="$SERVICE_DIR/build.log"
CURRENT_STEP=""

# ── Config reader ───────────────────────────────────────────────
get_config() {
    [ ! -f "$CONFIG" ] && return 0
    node -e "const c=require('$CONFIG'); const v='$1'.split('.').reduce((o,k)=>o&&o[k],c); process.stdout.write(v===false?'false':v===true?'true':String(v!=null?v:''))"
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
    HM_USER="$(get_config hm.user)"
else
    echo "FATAL: $CONFIG not found"
    exit 1
fi

# Required field
if [ -z "$HM_USER" ]; then
    echo "FATAL: hm.user not set in build.json"
    exit 1
fi

# Age key — use dotfile symlink set up by vault/build.sh setup system
: "${SOPS_AGE_KEY_FILE:=$HOME/.config/sops/age/keys.txt}"
export SOPS_AGE_KEY_FILE

# ── Error trap ──────────────────────────────────────────────────────
_on_error() {
    local rc=$?
    if [ -n "$CURRENT_STEP" ]; then
        log "FATAL: step '$CURRENT_STEP' failed (exit $rc)"
    fi
    exit "$rc"
}
trap _on_error ERR

# ── Logging: console + persistent build.log ───────────────────────────
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
    _exit=${PIPESTATUS[0]}
    set -e
    if [ "$_exit" -ne 0 ]; then
        log "FAILED (exit $_exit): $_desc"
        return "$_exit"
    fi
    log "OK: $_desc"
    return 0
}

# ── SSH multiplexing ────────────────────────────────────────────────
SSH_OPTS="-o ControlMaster=auto -o ControlPath=/tmp/ssh-hm-%r@%h -o ControlPersist=120"
ssh_vm() {
    ssh $SSH_OPTS "$DEPLOY_HOST" "$@"
}

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
    build)           CURRENT_STEP=build; step_build ;;
    secrets)         CURRENT_STEP=secrets; step_secrets ;;
    deploy)          CURRENT_STEP=deploy; step_deploy ;;
    compose)         CURRENT_STEP=compose; step_compose ;;
    docker-package)  CURRENT_STEP=build; step_build; CURRENT_STEP=secrets; step_secrets; CURRENT_STEP=docker-package; step_docker_package ;;
    docker-push)     CURRENT_STEP=docker-push; step_docker_push ;;
    all)             CURRENT_STEP=build; step_build; CURRENT_STEP=secrets; step_secrets ;;
    ship)
        if [ "$HM_DELIVERY" = "docker" ] && [ "$HM_REMOTE_BUILDER" != "true" ]; then
            CURRENT_STEP=build;          step_build
            CURRENT_STEP=secrets;        step_secrets
            CURRENT_STEP=docker-package; step_docker_package
            CURRENT_STEP=docker-push;    step_docker_push
            CURRENT_STEP=compose;        step_compose
        elif [ "$HM_DELIVERY" = "docker" ] && [ "$HM_REMOTE_BUILDER" = "true" ]; then
            log "Remote builder: deploy+compose (skip docker packaging)"
            CURRENT_STEP=build;   step_build
            CURRENT_STEP=secrets; step_secrets
            CURRENT_STEP=deploy;  step_deploy
            CURRENT_STEP=compose; step_compose
        else
            CURRENT_STEP=build;   step_build
            CURRENT_STEP=secrets; step_secrets
            CURRENT_STEP=deploy;  step_deploy
            CURRENT_STEP=compose; step_compose
        fi
        ;;
    clean)  [ -d "$DIST_DIR" ] && chmod -R u+w "$DIST_DIR" 2>/dev/null || true; rm -rf "$DIST_DIR" "$SERVICE_DIR/.closure-path"; log "Cleaned" ;;
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
