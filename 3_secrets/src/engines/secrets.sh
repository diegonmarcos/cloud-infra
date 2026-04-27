#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════
# Cloud secrets manager
#
# Structure:
#   secrets/
#   ├── secrets.sh          ← this script
#   ├── src/                ← encrypted .yaml (synced from cloud/)
#   └── dist/               ← decrypted outputs
#       ├── {name}.secrets          — KEY=VALUE env file
#       ├── {name}.json.secrets     — JSON object
#       └── cloud-secrets.json.secrets — consolidated
#
# Usage:
#   secrets.sh              — decrypt src/*.yaml → dist/
#   secrets.sh decrypt      — same as above
#   secrets.sh sync [dir]   — sync secrets.yaml from cloud/ into src/
#   secrets.sh all [dir]    — sync + decrypt
# ══════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Engine lives at: cloud/3_secrets/src/engines — 2 levels up = cloud/3_secrets
SECRETS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLOUD_ROOT="$(cd "$SECRETS_ROOT/.." && pwd)"
SRC_DIR="$SECRETS_ROOT/src/builds"
DIST_DIR="$SECRETS_ROOT/dist"

# ── sync: collect secrets.yaml from cloud source into src/ ──
cmd_sync() {
  local CLOUD_SOURCE_DIR="${1:-${CLOUD_SOURCE_DIR:-$CLOUD_ROOT}}"

  if [ ! -d "$CLOUD_SOURCE_DIR/a_solutions" ]; then
    echo "ERROR: cloud source not found at $CLOUD_SOURCE_DIR" >&2
    echo "Usage: secrets.sh sync [cloud-source-dir]" >&2
    exit 1
  fi

  echo "Syncing secrets: $CLOUD_SOURCE_DIR → $SRC_DIR/"

  mkdir -p "$SRC_DIR"
  rm -f "$SRC_DIR/"*.yaml

  find "$CLOUD_SOURCE_DIR/a_solutions" \
       "$CLOUD_SOURCE_DIR/b_infra/home-manager" \
       "$CLOUD_SOURCE_DIR/b_infra" \
    -name "secrets*.yaml" \
    -not -path "*/z_archive/*" -not -path "*/node_modules/*" \
    -not -path "*/dist/*" \
    -type f 2>/dev/null | sort -u | while read -r src; do
      rel=${src#$CLOUD_SOURCE_DIR/}
      rel=${rel#a_solutions/}
      rel=${rel#b_infra/}
      rel=$(echo "$rel" | awk -F/ '{
        out=""
        for(i=1;i<NF;i++) {
          if($i=="src") continue
          out=(out=="" ? $i : out"-"$i)
        }
        print out"-"$NF
      }')
      cp "$src" "$SRC_DIR/$rel"
  done

  local count
  count=$(ls "$SRC_DIR/"*.yaml 2>/dev/null | wc -l)
  echo "Synced $count secret files"
}

# ── decrypt: sops decrypt src/*.yaml → dist/ ──
cmd_decrypt() {
  local AGE_KEY="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"

  if [ ! -f "$AGE_KEY" ]; then
    echo "ERROR: Age key not found at $AGE_KEY" >&2
    exit 1
  fi

  if ! command -v sops >/dev/null 2>&1; then
    echo "ERROR: sops not found in PATH" >&2
    exit 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq not found in PATH" >&2
    exit 1
  fi

  export SOPS_AGE_KEY_FILE="$AGE_KEY"

  mkdir -p "$DIST_DIR"
  rm -f "$DIST_DIR/"*.secrets "$DIST_DIR/"*.json.secrets

  local count=0 failed=0
  local CONSOLIDATED="{}"

  for yaml in "$SRC_DIR"/*.yaml; do
    [ -f "$yaml" ] || continue
    local base
    base=$(basename "$yaml" .yaml)
    local out_env="$DIST_DIR/${base}.secrets"
    local out_json="$DIST_DIR/${base}.json.secrets"

    # Decrypt directly to JSON — no text parsing of YAML, structured data only.
    # This aggregator is a human-facing viewer (NOT a container deploy pipeline),
    # so it exports *everything* including _-prefixed metadata like _credentials.
    # The per-service container engine (1_workflows/.../step-secrets-decrypt.sh)
    # applies the _-prefix filter when producing .secrets for VMs.
    if SERVICE_JSON=$(sops -d --output-type json "$yaml" 2>/dev/null); then

      # 1. KEY=VALUE env file — flatten nested objects with dotted keys so
      #    _credentials.admin.password lands as a visible line. Values with $
      #    are single-quoted for docker-compose env_file compatibility.
      echo "$SERVICE_JSON" \
        | jq -r '
            [paths(scalars) as $p | {key: ($p|join(".")), value: (getpath($p) | tostring | gsub("\n"; "\\n"))}] |
            .[] |
            if (.value | test("[$]"))
            then "\(.key)='"'"'\(.value)'"'"'"
            else "\(.key)=\(.value)"
            end' \
        > "$out_env"

      # 2. JSON object — full nested structure preserved
      echo "$SERVICE_JSON" > "$out_json"

      # 3. Add to consolidated
      CONSOLIDATED=$(echo "$CONSOLIDATED" | jq --arg svc "$base" --argjson data "$SERVICE_JSON" '. + {($svc): $data}')

      count=$((count + 1))
      local lines
      lines=$(wc -l < "$out_env")
      echo "  OK  ${base} (${lines} keys)"
    else
      failed=$((failed + 1))
      echo "  FAIL ${base}" >&2
      rm -f "$out_env" "$out_json"
    fi
  done

  # Write consolidated
  echo "$CONSOLIDATED" | jq '.' > "$DIST_DIR/cloud-secrets.json.secrets"

  # 2026-04-27 migrated: cloud-data-secrets-env-var-names.json → _cloud-data-consolidated.json[.services.*.secret_env_vars]
  # Derive a {services: [{service, env_vars}]} schema from consolidated (per-service secret_env_vars arrays).
  local CONSOLIDATED_JSON=""
  for _candidate in \
    "/app/_cloud-data-consolidated.json" \
    "$CLOUD_ROOT/2_configs/dist/_cloud-data-consolidated.json" \
    "$CLOUD_ROOT/cloud-data/_cloud-data-consolidated.json" \
    "$CLOUD_ROOT/_cloud-data-consolidated.json"
  do
    if [ -f "$_candidate" ]; then
      CONSOLIDATED_JSON="$_candidate"
      break
    fi
  done
  if [ -n "$CONSOLIDATED_JSON" ]; then
    jq '{
      _generated: now | todate,
      _source: "_cloud-data-consolidated.json[.services.*.secret_env_vars]",
      services: (.services | to_entries | map({
        service: .key,
        folder: (.value.folder // null),
        vm: (.value.vm // null),
        env_vars: (.value.secret_env_vars // []),
        count: (.value.secret_env_vars // [] | length)
      }))
    }' "$CONSOLIDATED_JSON" > "$DIST_DIR/secrets-env-var-names.json"
    echo "Derived: dist/secrets-env-var-names.json (from $CONSOLIDATED_JSON[.services.*.secret_env_vars])"
  fi

  # Generate manifest.json
  local MANIFEST="[]"
  for f in "$DIST_DIR"/*.json.secrets; do
    [ -f "$f" ] || continue
    local base
    base=$(basename "$f" .json.secrets)
    MANIFEST=$(echo "$MANIFEST" | jq --arg file "dist/$(basename "$f")" --arg name "$base" '. + [{"file": $file, "name": $name}]')
  done
  echo "$MANIFEST" | jq '.' > "$SECRETS_ROOT/manifest.json"
  echo "Manifest: $(echo "$MANIFEST" | jq 'length') entries"

  echo ""
  echo "Done: ${count} decrypted | ${failed} failed"
  echo "Consolidated: dist/cloud-secrets.json.secrets ($(echo "$CONSOLIDATED" | jq 'keys | length') services)"
}

# ── dispatch ──
case "${1:-decrypt}" in
  sync)    cmd_sync "${2:-}" ;;
  decrypt) cmd_decrypt ;;
  all)     cmd_sync "${2:-}"; cmd_decrypt ;;
  *)       echo "Usage: secrets.sh [sync|decrypt|all] [cloud-source-dir]" >&2; exit 1 ;;
esac
