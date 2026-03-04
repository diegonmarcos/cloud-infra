#!/bin/sh
# AWS Terraform: src/*.tf → dist/ (terraform runs in dist/)
# Auth: AWS credentials from vault (~/.aws/credentials symlink)
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$DIR/src"
DIST_DIR="$DIR/dist"

# Vault paths — auto-detect mobile vs desktop
if [ -d "$HOME/git/vault/A0_keys" ]; then
    VAULT="$HOME/git/vault/A0_keys"
elif [ -d "/home/diego/Mounts/Git/vault/A0_keys" ]; then
    VAULT="/home/diego/Mounts/Git/vault/A0_keys"
else
    echo "ERROR: vault not found"; exit 1
fi

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }

# Auth — AWS CLI reads from ~/.aws/credentials (symlinked to vault)
export AWS_SHARED_CREDENTIALS_FILE="$VAULT/providers/aws/credentials"
export AWS_CONFIG_FILE="$VAULT/providers/aws/config"

# Run terraform in dist/ (state + providers live there)
tf() { (cd "$DIST_DIR" && terraform "$@"); }

# ── Build — copy src/*.tf → dist/ ──────────────────────────────────────
step_build() {
    log "Copying src/*.tf → dist/"
    mkdir -p "$DIST_DIR"
    cp "$SRC_DIR"/*.tf "$DIST_DIR/"
    log "Built → dist/"
}

# ── Init ────────────────────────────────────────────────────────────────
step_init() {
    step_build
    log "terraform init"
    tf init -upgrade
}

# ── Plan ────────────────────────────────────────────────────────────────
step_plan() {
    step_build
    log "terraform plan"
    tf plan
}

# ── Apply (interactive) ────────────────────────────────────────────────
step_apply() {
    step_build
    log "terraform apply"
    tf apply
}

# ── Ship (build + apply -auto-approve) ─────────────────────────────────
step_ship() {
    step_build
    log "terraform apply -auto-approve"
    tf apply -auto-approve
}

# ── Destroy ─────────────────────────────────────────────────────────────
step_destroy() {
    step_build
    log "terraform destroy"
    tf destroy
}

# ── Fmt ─────────────────────────────────────────────────────────────────
step_fmt() {
    log "terraform fmt"
    terraform fmt "$SRC_DIR"
}

# ── Clean — remove dist/ .tf copies only (keeps state + .terraform/) ──
step_clean() {
    log "Removing dist/*.tf"
    rm -f "$DIST_DIR"/*.tf
}

# ── Main ────────────────────────────────────────────────────────────────
echo "╔════════════════════════════════════════╗"
echo "║  AWS Terraform                         ║"
echo "╚════════════════════════════════════════╝"

case "${1:-plan}" in
    build)    step_build ;;
    init)     step_init ;;
    plan)     step_plan ;;
    apply)    step_apply ;;
    ship)     step_ship ;;
    destroy)  step_destroy ;;
    fmt)      step_fmt ;;
    clean)    step_clean ;;
    *)
        echo "Usage: $0 [build|init|plan|apply|ship|destroy|fmt|clean]"
        echo "  build    Copy src/*.tf → dist/"
        echo "  init     build + terraform init"
        echo "  plan     build + terraform plan (default)"
        echo "  apply    build + terraform apply (interactive)"
        echo "  ship     build + terraform apply -auto-approve"
        echo "  destroy  build + terraform destroy"
        echo "  fmt      terraform fmt src/"
        echo "  clean    Remove dist/*.tf (keeps state)"
        ;;
esac

log "Done."
