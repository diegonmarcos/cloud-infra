#!/bin/sh
# GCP Terraform helper — plan, apply, destroy
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="$DIR/terraform"

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }

step_init() {
    log "terraform init"
    terraform -chdir="$TF_DIR" init
}

step_plan() {
    log "terraform plan"
    export TF_VAR_ssh_public_key="${TF_VAR_ssh_public_key:-$(cat ~/git/vault/A0_keys/ssh/google_compute_engine.pub 2>/dev/null || echo FILL_FROM_VAULT)}"
    terraform -chdir="$TF_DIR" plan
}

step_apply() {
    log "terraform apply"
    export TF_VAR_ssh_public_key="${TF_VAR_ssh_public_key:-$(cat ~/git/vault/A0_keys/ssh/google_compute_engine.pub 2>/dev/null || echo FILL_FROM_VAULT)}"
    terraform -chdir="$TF_DIR" apply
}

step_destroy() {
    log "terraform destroy"
    terraform -chdir="$TF_DIR" destroy
}

step_fmt() {
    log "terraform fmt"
    terraform -chdir="$TF_DIR" fmt
}

echo "╔════════════════════════════════════════╗"
echo "║  GCP Terraform                         ║"
echo "╚════════════════════════════════════════╝"

case "${1:-plan}" in
    init)     step_init ;;
    plan)     step_plan ;;
    apply)    step_apply ;;
    destroy)  step_destroy ;;
    fmt)      step_fmt ;;
    *)
        echo "Usage: $0 [init|plan|apply|destroy|fmt]"
        echo "  init     terraform init"
        echo "  plan     terraform plan (default)"
        echo "  apply    terraform apply"
        echo "  destroy  terraform destroy"
        echo "  fmt      terraform fmt"
        ;;
esac

log "Done."
