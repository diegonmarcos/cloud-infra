# Step: Decrypt secrets.yaml via sops -> dist/.secrets + .secrets.d/ + .secrets.json
# Sourced by cloud-ship-container-engine.sh — do not execute directly
#
# Three lossless materialisations of the same decrypted material — every container
# gets all three auto-mounted by _shared/engine.nix when src/secrets.yaml is present:
#   .secrets        env_file (KEY=VALUE)        → $KEY in container env
#   .secrets.d/<KEY> one file per key            → /run/secrets/<KEY>
#   .secrets.json   {"KEY":"value", ...}          → /run/secrets.json
# All written mode 0600 so SSH keys / strict-perm consumers work without entrypoint chmod.
#
# Path: $DIST_DIR/.secrets (NOT $DIST_DIR/compose/.secrets).
# step_compose forces `--project-directory .` (deploy-compose.sh:89), pinning the
# compose project root to the SERVICE directory regardless of v1/v2 layout. With
# that flag, docker-compose resolves the YAML's `env_file: [".secrets"]` relative
# to the project root → /opt/containers/<svc>/.secrets. Putting secrets inside
# compose/ would only work if --project-directory pointed at the compose-file
# directory; it doesn't. Verified 2026-04-27 (ship run 24998852451).

step_secrets() {
    CURRENT_STEP="secrets"
    secrets_file="$SRC_DIR/secrets.yaml"

    if [ ! -f "$secrets_file" ]; then
        log "No secrets.yaml -- skipping"
        return 0
    fi

    SECRETS_DIR="$DIST_DIR"
    mkdir -p "$SECRETS_DIR"

    log "Decrypting secrets -> dist/.secrets{,.d/,.json}"

    # Decrypt once to JSON — all extraction done by jq, never parse secret values as text
    _secrets_json=$(sops -d --output-type json "$secrets_file")

    # ── .secrets dotenv (env_file format) ─────────────────────────────
    # Newlines escaped (env_file format can't carry literal \n).
    # Single-quote values containing $ so compose doesn't interpolate them.
    # Top-level keys starting with "_" are metadata (e.g. _credentials) — filtered out.
    echo "$_secrets_json" \
      | jq -r 'to_entries[] | select(.key | startswith("_") | not) |
          .value = (.value | tostring | gsub("\n"; "\\n")) |
          if (.value | test("[$]"))
          then "\(.key)='"'"'\(.value)'"'"'"
          else "\(.key)=\(.value)"
          end' \
      > "$SECRETS_DIR/.secrets"
    chmod 0600 "$SECRETS_DIR/.secrets"

    # ── .secrets.json (single canonical JSON) ──────────────────────────
    # For app-side consumption (Rust serde_json, Node require, jq) without
    # parsing the dotenv form. Same _-prefix filter as .secrets.
    echo "$_secrets_json" \
      | jq 'with_entries(select(.key | startswith("_") | not))' \
      > "$SECRETS_DIR/.secrets.json"
    chmod 0600 "$SECRETS_DIR/.secrets.json"

    # ── .secrets.d/<KEY> (one file per key) ────────────────────────────
    # jq -r preserves multi-line values byte-for-byte (PEM, SSH keys, certs).
    # Default dir 0700 / file 0600 — required for SSH `ssh -i` to accept a key.
    #
    # But .secrets.d/ is bind-mounted read-only into the container at /run/secrets,
    # and a container that runs as a NON-ROOT user (image UID != the deploy user
    # that owns these files) then can't traverse the 0700 dir or read the 0600
    # file — the app silently falls back / fails to load the secret. Such services
    # declare `secrets.container_readable = true` in build.json to get dir 0755 /
    # file 0644 (host is single-tenant; the file is already exposed to exactly the
    # container that would read it). Do NOT set this for services that mount an SSH
    # private key — ssh(1) refuses a group/other-readable key. Data-driven, default
    # stays strict. Fixed 2026-07-15 (g-workspace-mcp SA key unreadable by appuser).
    _cr=$(jq -r '.secrets.container_readable // false' "$SERVICE_DIR/build.json" 2>/dev/null || echo false)
    if [ "$_cr" = "true" ]; then _dmode=0755; _fmode=0644; else _dmode=0700; _fmode=0600; fi
    mkdir -p "$SECRETS_DIR/.secrets.d"
    chmod "$_dmode" "$SECRETS_DIR/.secrets.d"
    for key in $(echo "$_secrets_json" | jq -r 'keys[] | select(startswith("_") | not)'); do
        echo "$_secrets_json" | jq -r --arg k "$key" '.[$k] | tostring' > "$SECRETS_DIR/.secrets.d/$key"
        chmod "$_fmode" "$SECRETS_DIR/.secrets.d/$key"
    done
    unset _secrets_json
    log "Secrets split -> .secrets.d/ ($(ls "$SECRETS_DIR/.secrets.d" | wc -l) files, dir $_dmode / files $_fmode)"

    # Extract JWKS key as PEM file (multi-line value can't go in env_file)
    if [ -n "${JWKS_FILE:-}" ] && [ -f "$SRC_DIR/$JWKS_FILE" ]; then
        JWKS_DEST_PATH="${JWKS_DEST:-config/oidc_jwks.pem}"
        mkdir -p "$DIST_DIR/$(dirname "$JWKS_DEST_PATH")"
        sops -d --extract '["key"]' "$SRC_DIR/$JWKS_FILE" > "$DIST_DIR/$JWKS_DEST_PATH"
        chmod 600 "$DIST_DIR/$JWKS_DEST_PATH"
        log "JWKS key -> $JWKS_DEST_PATH"
    fi

    # Write secrets hash for change detection (engine reads $SERVICE_DIR/.secrets-hash-new)
    sha256sum "$SECRETS_DIR/.secrets" 2>/dev/null | cut -c1-16 > "$SERVICE_DIR/.secrets-hash-new"

    log "Secrets decrypted"
}
