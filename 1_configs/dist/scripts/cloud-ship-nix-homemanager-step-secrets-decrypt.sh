# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/gha/scripts/cloud-ship-nix-homemanager-step-secrets-decrypt.sh
# ║   Engine : 1_configs/src/gha/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Step: Decrypt secrets.yaml via sops -> dist/.secrets + dist/.secrets.d/
# Sourced by cloud-ship-nix-homemanager-engine.sh — do not execute directly

step_secrets() {
    secrets_file="$SRC_DIR/secrets.yaml"

    if [ ! -f "$secrets_file" ]; then
        log "No secrets.yaml — skipping"
        return 0
    fi

    log "Decrypting secrets -> dist/.secrets + .secrets.d/"
    mkdir -p "$DIST_DIR/.secrets.d"

    if ! command -v yq >/dev/null 2>&1; then
        log "ERROR: yq required for YAML->env conversion"
        return 1
    fi

    # Decrypt → write ALL keys to both:
    #   .secrets     = KEY=VALUE lines (docker-compose env_file)
    #   .secrets.d/  = one raw file per key (ssh-keys.nix, file mounts)
    DECRYPTED=$(sops -d "$secrets_file")
    KEY_COUNT=0
    : > "$DIST_DIR/.secrets"

    for key in $(printf '%s' "$DECRYPTED" | yq -r 'keys | .[] | select(. != "sops" and (. | test("^_") | not))'); do
        val=$(printf '%s' "$DECRYPTED" | yq -r ".[\"$key\"]")
        # .secrets.d/KEY — raw file
        printf '%s\n' "$val" > "$DIST_DIR/.secrets.d/$key"
        chmod 600 "$DIST_DIR/.secrets.d/$key"
        # .secrets — KEY=VALUE
        printf '%s=%s\n' "$key" "$val" >> "$DIST_DIR/.secrets"
        KEY_COUNT=$((KEY_COUNT + 1))
    done

    log "Secrets decrypted ($KEY_COUNT keys)"
}
