# Step: Terraform import (reads existing resources into state)
# Sourced by cloud-ship-container-engine.sh

step_terraform_import() {
    CURRENT_STEP="terraform-import"
    [ "$TERRAFORM_DEPLOY" != "true" ] && { log "No deploy.terraform -- skipping"; return 0; }
    [ ! -d "$DIST_DIR" ] && { log "No dist/ -- run build first"; return 1; }

    if ! command -v terraform >/dev/null 2>&1; then
        log_error "terraform not found on PATH"
        return 1
    fi

    IMPORT_SCRIPT="$SRC_DIR/import.sh"
    if [ ! -f "$IMPORT_SCRIPT" ]; then
        log_error "No import.sh found in src/"
        return 1
    fi

    # Decrypt state if encrypted version exists
    _tf_state_decrypt

    # Generate tfvars (same as plan step)
    TFVARS_TEMPLATE="$SRC_DIR/${TERRAFORM_TFVARS_TEMPLATE:-terraform.tfvars.template}"
    if [ -f "$TFVARS_TEMPLATE" ]; then
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
    fi

    log "terraform init"
    (cd "$DIST_DIR" && terraform init -upgrade -input=false)

    log "Running import.sh (in dist/)"
    (cd "$DIST_DIR" && bash "$DIST_DIR/import.sh")

    log "terraform plan (verify imports)"
    (cd "$DIST_DIR" && terraform plan)

    # Re-encrypt state
    _tf_state_encrypt

    log "Terraform import complete"
}

# Decrypt sops-encrypted terraform state into dist/
_tf_state_decrypt() {
    local enc_state="$SRC_DIR/terraform.tfstate.enc"
    local plain_state="$DIST_DIR/terraform.tfstate"
    if [ -f "$enc_state" ]; then
        log "Decrypting terraform.tfstate.enc"
        sops -d --output-type json "$enc_state" > "$plain_state"
    fi
}

# Encrypt terraform state back to src/ (after apply/import)
_tf_state_encrypt() {
    local plain_state="$DIST_DIR/terraform.tfstate"
    local enc_state="$SRC_DIR/terraform.tfstate.enc"
    if [ -f "$plain_state" ] && [ -s "$plain_state" ]; then
        log "Encrypting terraform.tfstate → terraform.tfstate.enc"
        # sops needs the file to have the .enc name for creation_rules matching
        cp "$plain_state" "$enc_state"
        sops -e -i --input-type json "$enc_state"
        log "State encrypted ($(wc -c < "$enc_state") bytes)"
    fi
}
