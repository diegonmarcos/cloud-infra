# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_cicd/src/scripts/cloud-ship-container-step-terraform-plan.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Step: Terraform plan (non-destructive)
# Sourced by cloud-ship-container-engine.sh

step_terraform_plan() {
    CURRENT_STEP="terraform-plan"
    [ "$TERRAFORM_DEPLOY" != "true" ] && { log "No deploy.terraform -- skipping"; return 0; }
    [ ! -d "$DIST_DIR" ] && { log "No dist/ -- run build first"; return 1; }

    if ! command -v terraform >/dev/null 2>&1; then
        log_error "terraform not found on PATH"
        return 1
    fi

    # Generate tfvars from template (always), then substitute secrets (if present)
    TFVARS_TEMPLATE="$SRC_DIR/${TERRAFORM_TFVARS_TEMPLATE:-terraform.tfvars.template}"
    if [ -f "$TFVARS_TEMPLATE" ] && [ ! -f "$DIST_DIR/terraform.tfvars" ]; then
        cp "$TFVARS_TEMPLATE" "$DIST_DIR/terraform.tfvars"
        if [ -f "$DIST_DIR/.secrets" ]; then
            log "Substituting secrets into terraform.tfvars"
            while IFS='=' read -r key val; do
                case "$key" in "") continue ;; esac
                awk -v pat="= \"INJECTED_FROM_SECRETS\"" -v key="$key" -v val="$val" '{
                    if (index($0, key) == 1 && index($0, pat)) {
                        print key " = \"" val "\""
                    } else {
                        print
                    }
                }' "$DIST_DIR/terraform.tfvars" > "$DIST_DIR/terraform.tfvars.tmp"
                mv "$DIST_DIR/terraform.tfvars.tmp" "$DIST_DIR/terraform.tfvars"
            done < "$DIST_DIR/.secrets"
        fi
        log "terraform.tfvars ready ($(grep -c '=' "$DIST_DIR/terraform.tfvars") vars)"
    fi

    # Decrypt state if encrypted version exists
    _tf_state_decrypt

    log "terraform init"
    (cd "$DIST_DIR" && terraform init -upgrade -input=false) >/dev/null 2>&1
    log "terraform plan $*"
    (cd "$DIST_DIR" && terraform plan "$@")
}
