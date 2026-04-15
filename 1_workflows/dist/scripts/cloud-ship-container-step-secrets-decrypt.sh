# Step: Decrypt secrets.yaml via sops -> dist/.secrets + dist/.secrets.d/
# Sourced by cloud-ship-container-engine.sh — do not execute directly

step_secrets() {
    CURRENT_STEP="secrets"
    secrets_file="$SRC_DIR/secrets.yaml"

    if [ ! -f "$secrets_file" ]; then
        log "No secrets.yaml -- skipping"
        return 0
    fi

    log "Decrypting secrets -> dist/.secrets"
    mkdir -p "$DIST_DIR"

    # sops decrypt → JSON (handles all types: str, int, bool) → dotenv
    # Single-quote values containing $ so compose doesn't interpolate them
    sops -d --output-type json "$secrets_file" \
      | jq -r 'to_entries[] | if (.value | tostring | test("[$]"))
          then "\(.key)='"'"'\(.value | tostring)'"'"'"
          else "\(.key)=\(.value | tostring)"
          end' \
      > "$DIST_DIR/.secrets"

    # Split .secrets into per-file .secrets.d/ (one file per KEY, content = VALUE)
    # Enables Docker/Authelia _FILE suffix pattern: SECRET_FILE=/config/.secrets.d/KEY
    mkdir -p "$DIST_DIR/.secrets.d"
    while IFS='=' read -r key val; do
        case "$key" in ""|\#*) continue ;; esac
        # Strip surrounding single quotes from compose-escaped values
        val="${val#\'}"
        val="${val%\'}"
        printf '%s' "$val" > "$DIST_DIR/.secrets.d/$key"
    done < "$DIST_DIR/.secrets"
    log "Secrets split -> .secrets.d/ ($(ls "$DIST_DIR/.secrets.d" | wc -l) files)"

    # Extract JWKS key as PEM file (multi-line value can't go in env_file)
    if [ -n "$JWKS_FILE" ] && [ -f "$SRC_DIR/$JWKS_FILE" ]; then
        JWKS_DEST_PATH="${JWKS_DEST:-config/oidc_jwks.pem}"
        mkdir -p "$DIST_DIR/$(dirname "$JWKS_DEST_PATH")"
        sops -d --extract '["key"]' "$SRC_DIR/$JWKS_FILE" > "$DIST_DIR/$JWKS_DEST_PATH"
        chmod 600 "$DIST_DIR/$JWKS_DEST_PATH"
        log "JWKS key -> $JWKS_DEST_PATH"
    fi

    # Write secrets hash for change detection
    sha256sum "$DIST_DIR/.secrets" 2>/dev/null | cut -c1-16 > "$SERVICE_DIR/.secrets-hash-new"

    log "Secrets decrypted"
}
