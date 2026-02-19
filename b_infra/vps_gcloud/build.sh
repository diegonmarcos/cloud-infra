#!/bin/sh
# GCP Terraform helper — plan, apply, destroy
# Auth: service account key from vault (GOOGLE_APPLICATION_CREDENTIALS)
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$DIR/src"
DIST_DIR="$DIR/dist"
VAULT="$HOME/git/vault/A0_keys"

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }

# Auth + vars
export GOOGLE_APPLICATION_CREDENTIALS="$VAULT/providers/gcloud/api/diego-cli-key.json"
export TF_VAR_ssh_public_key="${TF_VAR_ssh_public_key:-$(cat "$VAULT/ssh/google_compute_engine.pub" 2>/dev/null || echo FILL_FROM_VAULT)}"

# terraform 1.8 -chdir is unreliable — use cd + subshell
tf() { (cd "$DIST_DIR" && terraform "$@"); }

step_build() {
    log "Copying main.tf → dist/"
    mkdir -p "$DIST_DIR"
    cp "$SRC_DIR/main.tf" "$DIST_DIR/main.tf"
}

step_init() {
    step_build
    log "terraform init"
    tf init -upgrade
}

step_plan() {
    step_build
    log "terraform plan"
    tf plan
}

step_apply() {
    step_build
    log "terraform apply"
    tf apply
}

step_ship() {
    step_build
    log "terraform apply -auto-approve"
    tf apply -auto-approve
}

step_destroy() {
    log "terraform destroy"
    tf destroy
}

step_fmt() {
    log "terraform fmt"
    terraform fmt "$SRC_DIR/main.tf"
}

step_clean() {
    log "Removing dist/"
    rm -rf "$DIST_DIR"
}

echo "╔════════════════════════════════════════╗"
echo "║  GCP Terraform                         ║"
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
        echo "  build    Copy main.tf → dist/"
        echo "  init     build + terraform init"
        echo "  plan     build + terraform plan (default)"
        echo "  apply    build + terraform apply (interactive)"
        echo "  ship     build + terraform apply -auto-approve"
        echo "  destroy  terraform destroy"
        echo "  fmt      terraform fmt"
        echo "  clean    Remove dist/"
        ;;
esac

log "Done."
