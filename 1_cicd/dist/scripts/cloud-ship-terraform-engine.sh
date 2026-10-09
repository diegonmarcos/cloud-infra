#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_cicd/src/scripts/cloud-ship-terraform-engine.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ╔══════════════════════════════════════════════════════════════════╗
# ║ Terraform Engine — dedicated dispatcher for c_vps/* providers    ║
# ║                                                                  ║
# ║ Symlinked as build.sh in each c_vps/<provider>/ directory.       ║
# ║ Reuses the same terraform step files as the container engine —   ║
# ║ does NOT include docker/compose/ship logic.                      ║
# ║                                                                  ║
# ║ Pipeline:                                                        ║
# ║   build      copy src/*.tf + terraform.json → dist/              ║
# ║   secrets    sops -d src/secrets.yaml → dist/.secrets            ║
# ║   plan       terraform plan (non-destructive)                    ║
# ║   apply      terraform init + apply (destructive — confirms)     ║
# ║   import     run src/import.sh against dist/ (state import)      ║
# ║   ship       build + secrets + apply                             ║
# ║   clean      rm -rf dist/                                        ║
# ╚══════════════════════════════════════════════════════════════════╝
set -e

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_NAME="$(basename "$SERVICE_DIR" | sed 's/^[a-z]*-[a-z]*_//; s/^vps_//')"
SRC_DIR="$SERVICE_DIR/src"
DIST_DIR="$SERVICE_DIR/dist"
CONFIG="$SERVICE_DIR/build.json"
STEPS_DIR="$(cd "$(dirname "$0")/../../1_cicd/src/scripts" 2>/dev/null && pwd)"
[ -z "$STEPS_DIR" ] && STEPS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# Shared lib: stamps every dist/ artifact with the GENERATED-FILE banner.
#
# 2026-08-12: this pointed at $STEPS_DIR/../../lib/inject-header.sh — i.e.
# 1_cicd/lib/ — which does not exist. The reorg in ead280004 ("cloud repos moved
# to the root") left the lib at 9_others/src/inject-header.sh without updating
# this line, so EVERY project symlinking to this engine (12 of them) died on
#     .../1_cicd/src/scripts/../../lib/inject-header.sh: No such file or directory
# and could not regenerate dist/ at all.
#
# That is not cosmetic: GHA deploys dist/, so a dist/ that cannot be rebuilt
# silently keeps shipping whatever it last contained. It is exactly how
# c_vps/vps_oci/dist/main.tf stayed missing the entire IPv6 build-out that
# src/main.tf already had — the work was written and never shipped, and nothing
# reported a problem because the generator was never reached.
INJECT_HEADER="$STEPS_DIR/../../../9_others/src/inject-header.sh"
ENGINE_NAME="1_cicd/src/scripts/cloud-ship-terraform-engine.sh"
export INJECT_HEADER ENGINE_NAME

log()       { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }
log_error() { printf "\033[0;31m[%s] ERROR: %s\033[0m\n" "$(date '+%H:%M:%S')" "$1" >&2; }

get_config() {
    [ ! -f "$CONFIG" ] && return 0
    if command -v node >/dev/null 2>&1; then
        node -e "const c=require('$CONFIG'); const v='$1'.split('.').reduce((o,k)=>o&&o[k],c); process.stdout.write(String(v||''))"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import json; c=json.load(open('$CONFIG')); v='$1'.split('.'); r=c; exec('for k in v: r=r.get(k,{}) if isinstance(r,dict) else {}'); print(r if isinstance(r,str) else '',end='')"
    fi
}

if [ -f "$CONFIG" ]; then
    TERRAFORM_DEPLOY="$(get_config deploy.terraform)"
    TERRAFORM_TFVARS_TEMPLATE="$(get_config terraform.tfvars_template)"
fi
[ -z "$TERRAFORM_DEPLOY" ] && TERRAFORM_DEPLOY="true"   # c_vps default

# ── Step: build (copy src/ → dist/) ────────────────────────────────────
step_build() {
    [ ! -d "$SRC_DIR" ] && { log_error "no src/ in $SERVICE_DIR"; return 1; }
    log "Build: $SERVICE_NAME (terraform)"
    mkdir -p "$DIST_DIR"
    # Copy *.tf, *.json, *.template, *.sh, *.tfstate.enc, oci-config.template, etc.
    # Banner is injected for every copied file (dist/ is engine output).
    for f in "$SRC_DIR"/*.tf "$SRC_DIR"/*.json "$SRC_DIR"/*.template "$SRC_DIR"/*.tpl "$SRC_DIR"/*.sh "$SRC_DIR"/*.tfstate.enc "$SRC_DIR"/secrets.yaml; do
        [ -e "$f" ] || continue
        "$INJECT_HEADER" file "$f" "$DIST_DIR/$(basename "$f")"
    done
    # Recursively copy subdirs (e.g. billing/ for vps_gcloud)
    for d in "$SRC_DIR"/*/; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        "$INJECT_HEADER" tree "$d" "$DIST_DIR/$name"
    done
    log "src/ → dist/ done"
}

# ── Step: secrets ──────────────────────────────────────────────────────
step_secrets() {
    if [ -f "$STEPS_DIR/cloud-ship-container-step-secrets-decrypt.sh" ]; then
        # Reuse the canonical secrets step
        . "$STEPS_DIR/cloud-ship-container-step-secrets-decrypt.sh"
        step_secrets_decrypt 2>/dev/null || step_secrets 2>/dev/null || true
    else
        [ -f "$SRC_DIR/secrets.yaml" ] || return 0
        log "sops -d secrets.yaml → dist/.secrets"
        sops -d --output-type dotenv "$SRC_DIR/secrets.yaml" > "$DIST_DIR/.secrets"
    fi
}

# ── Steps: terraform-{apply,plan,import} (sourced) ─────────────────────
[ -f "$STEPS_DIR/cloud-ship-container-step-terraform-apply.sh" ] && \
    . "$STEPS_DIR/cloud-ship-container-step-terraform-apply.sh"
[ -f "$STEPS_DIR/cloud-ship-container-step-terraform-plan.sh" ] && \
    . "$STEPS_DIR/cloud-ship-container-step-terraform-plan.sh"
[ -f "$STEPS_DIR/cloud-ship-container-step-terraform-import.sh" ] && \
    . "$STEPS_DIR/cloud-ship-container-step-terraform-import.sh"

# ── Dispatcher ─────────────────────────────────────────────────────────
case "${1:-help}" in
    build)        step_build ;;
    secrets)      step_secrets ;;
    plan)         shift; step_build; step_secrets; step_terraform_plan "$@" ;;
    apply|terraform)
                  step_build; step_secrets; step_terraform ;;
    import)       step_build; step_secrets; step_terraform_import ;;
    ship)         step_build; step_secrets; step_terraform ;;
    clean)        rm -rf "$DIST_DIR"; log "removed $DIST_DIR" ;;
    test)         "${CLOUD_ROOT:?CLOUD_ROOT unset}/a_solutions/_shared/test-src-terraform.sh" "$SRC_DIR" \
                  && "${CLOUD_ROOT:?CLOUD_ROOT unset}/a_solutions/_shared/test-dist-terraform.sh" "$DIST_DIR" ;;
    help|*)
        echo "Usage: $(basename "$0") [build|secrets|plan|apply|import|ship|clean|test]"
        echo "  build    Copy src/*.tf → dist/"
        echo "  secrets  Decrypt src/secrets.yaml → dist/.secrets"
        echo "  plan     build + secrets + terraform plan"
        echo "  apply    build + secrets + terraform init + apply (destructive)"
        echo "  import   build + secrets + run src/import.sh in dist/"
        echo "  ship     alias for apply"
        echo "  clean    rm -rf dist/"
        echo "  test     run src/dist validators"
        ;;
esac
