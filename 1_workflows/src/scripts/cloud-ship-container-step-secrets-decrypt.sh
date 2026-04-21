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

    # Decrypt once to JSON — all extraction done by jq, never parse secret values as text
    _secrets_json=$(sops -d --output-type json "$secrets_file")

    # Generate .secrets dotenv (newlines escaped for docker-compose env_file compatibility)
    # Single-quote values containing $ so compose doesn't interpolate them.
    # Top-level keys starting with "_" are metadata (e.g. _credentials with url/user/password
    # companions for hashed secrets) — filtered out so they never reach the VM/container.
    echo "$_secrets_json" \
      | jq -r 'to_entries[] | select(.key | startswith("_") | not) |
          .value = (.value | tostring | gsub("\n"; "\\n")) |
          if (.value | test("[$]"))
          then "\(.key)='"'"'\(.value)'"'"'"
          else "\(.key)=\(.value)"
          end' \
      > "$DIST_DIR/.secrets"

    # Write each secret as individual file — jq extracts values directly, NO text parsing.
    # Same _-prefix filter: metadata never materialises as a file on the VM.
    mkdir -p "$DIST_DIR/.secrets.d"
    for key in $(echo "$_secrets_json" | jq -r 'keys[] | select(startswith("_") | not)'); do
        echo "$_secrets_json" | jq -r --arg k "$key" '.[$k] | tostring' > "$DIST_DIR/.secrets.d/$key"
    done
    unset _secrets_json
    log "Secrets split -> .secrets.d/ ($(ls "$DIST_DIR/.secrets.d" | wc -l) files)"

    # Extract JWKS key as PEM file (multi-line value can't go in env_file)
    if [ -n "${JWKS_FILE:-}" ] && [ -f "$SRC_DIR/$JWKS_FILE" ]; then
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
