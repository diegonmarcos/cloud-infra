#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/scripts/audit-credentials-coverage.sh
# ║   Engine : 1_configs/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ════════════════════════════════════════════════════════════════════════
# audit-credentials-coverage.sh
#
# Walks every sops-encrypted secrets.yaml in the cloud repo (skipping
# z_archive, dist/, node_modules, .git, _shared templates) and reports:
#   - top-level non-"_" keys (app-facing secrets)
#   - whether a "_credentials" block exists
#   - whether every non-"_" key is referenced inside _credentials.<*>.<any string>
#   - rough classification per key (hash / token / password / url / multi / other)
#
# Usage:
#   audit-credentials-coverage.sh                 # stdout = markdown
#   audit-credentials-coverage.sh --csv PATH      # ALSO write a CSV
#   audit-credentials-coverage.sh --quiet         # only write CSV, no stdout
# ════════════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUD_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DEFAULT_CSV="$CLOUD_ROOT/2_secrets/dist/coverage-audit.csv"

CSV_OUT=""
QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --csv)   CSV_OUT="$2"; shift 2 ;;
    --quiet) QUIET=1; CSV_OUT="${CSV_OUT:-$DEFAULT_CSV}"; shift ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

command -v sops >/dev/null || { echo "ERROR: sops not in PATH" >&2; exit 1; }
command -v jq   >/dev/null || { echo "ERROR: jq not in PATH" >&2; exit 1; }

classify_value() {
  local v="$1"
  case "$v" in
    \$2[aby]\$*|\$argon2*|\$pbkdf2*|\$bcrypt*) echo hash ;;
    http://*|https://*) echo url ;;
    "") echo empty ;;
    *$'\n'*) echo multi ;;
    *)
      local len=${#v}
      if [ "$len" -ge 24 ] && [[ "$v" != *" "* ]]; then echo token
      else echo other
      fi ;;
  esac
}

# Skip z_archive / dist outputs / node_modules / .git / _shared templates
mapfile -t ALL_FILES < <(
  find "$CLOUD_ROOT" -name 'secrets*.yaml' 2>/dev/null \
    | grep -v '/z_archive/' \
    | grep -v '/z-archive/' \
    | grep -v '/dist/' \
    | grep -v '/node_modules/' \
    | grep -v '/.git/' \
    | grep -v '/_shared/' \
    | sort
)

if [ ${#ALL_FILES[@]} -eq 0 ]; then
  echo "ERROR: no secrets.yaml files found under $CLOUD_ROOT" >&2
  exit 1
fi

TOTAL=0; OK=0; GAPS=0; NO_BLOCK=0; FAILED=0
declare -a RESULT_ROWS=()
declare -a STDOUT_ROWS=()

for f in "${ALL_FILES[@]}"; do
  TOTAL=$((TOTAL + 1))
  rel="${f#$CLOUD_ROOT/}"

  if ! json=$(sops -d --output-type json "$f" 2>/dev/null); then
    FAILED=$((FAILED + 1))
    RESULT_ROWS+=("\"$rel\",\"\",\"\",\"DECRYPT_FAIL\",\"\"")
    STDOUT_ROWS+=("| \`$rel\` | — | — | ❌ DECRYPT_FAIL |")
    continue
  fi

  mapfile -t TOP_KEYS < <(printf '%s' "$json" | jq -r 'keys[] | select(startswith("_") | not)')
  HAS_CRED=$(printf '%s' "$json" | jq 'has("_credentials")')

  REF_VALUES=""
  if [ "$HAS_CRED" = "true" ]; then
    REF_VALUES=$(printf '%s' "$json" | jq -r '
      [ ._credentials // {} | to_entries[]? |
        .value as $cred |
        ($cred | to_entries[]? | .value | select(type == "string"))
      ] | .[]?' 2>/dev/null || echo "")
  fi

  missing=""
  classes=""
  for k in "${TOP_KEYS[@]:-}"; do
    [ -z "$k" ] && continue
    v=$(printf '%s' "$json" | jq -r --arg k "$k" '.[$k] | if type == "string" then . else tojson end')
    cls=$(classify_value "$v")
    classes="${classes:+$classes,}${k}:${cls}"
    if [ "$HAS_CRED" = "true" ] && printf '%s\n' "$REF_VALUES" | grep -F -q -x -- "$v"; then
      :
    else
      missing="${missing:+$missing,}${k}"
    fi
  done

  key_count=${#TOP_KEYS[@]}
  if [ "$HAS_CRED" != "true" ]; then
    NO_BLOCK=$((NO_BLOCK + 1))
    status="NO_CREDENTIALS"
    icon="⚠️"
  elif [ -n "$missing" ]; then
    GAPS=$((GAPS + 1))
    status="UNCOVERED:$missing"
    icon="🟡"
  else
    OK=$((OK + 1))
    status="OK"
    icon="✅"
  fi

  safe_classes=$(printf '%s' "$classes" | sed 's/"/""/g')
  safe_status=$(printf '%s' "$status" | sed 's/"/""/g')
  RESULT_ROWS+=("\"$rel\",\"$key_count\",\"$safe_classes\",\"$safe_status\",\"$HAS_CRED\"")
  STDOUT_ROWS+=("| \`$rel\` | $key_count | ${classes:--} | $icon $status |")
done

if [ -n "$CSV_OUT" ]; then
  mkdir -p "$(dirname "$CSV_OUT")"
  {
    echo "file,key_count,classes,status,has_credentials_block"
    printf '%s\n' "${RESULT_ROWS[@]}"
  } > "$CSV_OUT"
fi

if [ "$QUIET" -eq 0 ]; then
  echo "# Credentials coverage audit"
  echo ""
  echo "Scanned: **$TOTAL files**"
  echo "- ✅ fully covered: $OK"
  echo "- 🟡 partial coverage: $GAPS"
  echo "- ⚠️ no \`_credentials\` block: $NO_BLOCK"
  echo "- ❌ decrypt failed: $FAILED"
  echo ""
  [ -n "$CSV_OUT" ] && echo "CSV: \`${CSV_OUT#$CLOUD_ROOT/}\`"
  echo ""
  echo "| file | keys | classes | status |"
  echo "|------|-----:|---------|--------|"
  printf '%s\n' "${STDOUT_ROWS[@]}"
fi

if [ $((GAPS + NO_BLOCK + FAILED)) -gt 0 ]; then
  exit 1
fi
