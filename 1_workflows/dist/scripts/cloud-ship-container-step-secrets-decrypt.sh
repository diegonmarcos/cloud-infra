# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_workflows/src/scripts/cloud-ship-container-step-secrets-decrypt.sh
# ║   Engine : 1_workflows/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Step: Decrypt secrets.yaml via sops -> dist[/compose]/.secrets + .secrets.d/ + .secrets.json
# Sourced by cloud-ship-container-engine.sh — do not execute directly
#
# Three lossless materialisations of the same decrypted material — every container
# gets all three auto-mounted by _shared/engine.nix when src/secrets.yaml is present:
#   .secrets        env_file (KEY=VALUE)        → $KEY in container env
#   .secrets.d/<KEY> one file per key            → /run/secrets/<KEY>
#   .secrets.json   {"KEY":"value", ...}          → /run/secrets.json
# All written mode 0600 so SSH keys / strict-perm consumers work without entrypoint chmod.
#
# Layout-aware (LAYOUT_V2 exported by cloud-ship-container-engine.sh):
#   v1 — secrets land at dist/.secrets (compose at dist/docker-compose.yml — relative env_file resolves)
#   v2 — secrets land at dist/compose/.secrets (compose at dist/compose/docker-compose.yml).
#        Without this, `env_file: [".secrets"]` in the v2 compose resolves to compose/.secrets
#        and aborts: "env file ... not found". Bug surfaced 2026-04-27 on c3-services-mcp + mail-mcp.

step_secrets() {
    CURRENT_STEP="secrets"
    secrets_file="$SRC_DIR/secrets.yaml"

    if [ ! -f "$secrets_file" ]; then
        log "No secrets.yaml -- skipping"
        return 0
    fi

    # Layout-aware secrets dir — sibling to compose YAML so env_file: [".secrets"] resolves.
    SECRETS_DIR="$DIST_DIR"
    [ "${LAYOUT_V2:-0}" = "1" ] && SECRETS_DIR="$DIST_DIR/compose"
    mkdir -p "$SECRETS_DIR"

    log "Decrypting secrets -> ${SECRETS_DIR#$SERVICE_DIR/}/.secrets{,.d/,.json}"

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
    # Mode 0600 is required for SSH `ssh -i` to accept the key.
    mkdir -p "$SECRETS_DIR/.secrets.d"
    chmod 0700 "$SECRETS_DIR/.secrets.d"
    for key in $(echo "$_secrets_json" | jq -r 'keys[] | select(startswith("_") | not)'); do
        echo "$_secrets_json" | jq -r --arg k "$key" '.[$k] | tostring' > "$SECRETS_DIR/.secrets.d/$key"
        chmod 0600 "$SECRETS_DIR/.secrets.d/$key"
    done
    unset _secrets_json
    log "Secrets split -> .secrets.d/ ($(ls "$SECRETS_DIR/.secrets.d" | wc -l) files, mode 0600)"

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
