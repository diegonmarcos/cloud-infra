#!/usr/bin/env bash
# Fixture-driven integration test for the secrets pipeline.
# Creates a sops-encrypted YAML with FOO=bar + _credentials.x.password=p
# and asserts each consumer's expected shape:
#   1. container engine     → .secrets has FOO only; no _-keys
#   2. container engine     → .secrets.d/ has FOO only; no _-files
#   3. home-manager engine  → same asserts
#   4. viewer engine        → .secrets + .json.secrets show EVERYTHING
#   5. mail-mcp-style boot  → sourcing won't set _-prefix env vars
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUD_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPTS_DIR="$CLOUD_ROOT/src/scripts"

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

log()  { echo "  [test] $*"; }
vlog() { [ "$VERBOSE" -eq 1 ] && echo "  [v] $*"; return 0; }

PASS=0; FAIL=0
assert() {
  local name="$1"; local ok="$2"
  if [ "$ok" = "1" ]; then
    echo "  ✅ $name"; PASS=$((PASS + 1))
  else
    echo "  ❌ $name"; FAIL=$((FAIL + 1))
  fi
}

WORK=$(mktemp -d -t secrets-roundtrip.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
vlog "workspace: $WORK"

cat > "$WORK/secrets.plain.yaml" <<'YAML'
FOO: bar
_credentials:
  x:
    url: https://example.test
    username: admin
    password: p
    hashed: '$2y$10$placeholder'
    note: test fixture
YAML

AGE_RECIPIENT=$(awk '/^keys:/{flag=1;next}/^creation_rules/{flag=0}flag&&/age1/{print $3; exit}' "$CLOUD_ROOT/../.sops.yaml")
[ -z "$AGE_RECIPIENT" ] && { echo "ERROR: no age recipient in .sops.yaml" >&2; exit 1; }
vlog "recipient: $AGE_RECIPIENT"
cat > "$WORK/.sops.yaml" <<SOPS
creation_rules:
  - path_regex: .*\\.yaml$
    age: $AGE_RECIPIENT
SOPS
( cd "$WORK" && sops --encrypt secrets.plain.yaml ) > "$WORK/secrets.yaml"

# ─── TEST 1+2: container engine ───
echo ""
echo "─── Container engine ───"

SRC_DIR="$WORK/srv/src"
DIST_DIR="$WORK/srv/dist"
SERVICE_DIR="$WORK/srv"
mkdir -p "$SRC_DIR" "$DIST_DIR"
cp "$WORK/secrets.yaml" "$SRC_DIR/secrets.yaml"

CURRENT_STEP=""
log_inline() { vlog "[engine] $*"; }
log() { log_inline "$@"; }

# shellcheck disable=SC1091
. "$SCRIPTS_DIR/cloud-ship-container-step-secrets-decrypt.sh"
step_secrets

grep -q '^_' "$DIST_DIR/.secrets"                 && CONT_DOTENV_LEAK=1 || CONT_DOTENV_LEAK=0
ls "$DIST_DIR/.secrets.d" | grep -q '^_'          && CONT_FILE_LEAK=1 || CONT_FILE_LEAK=0
grep -q '^FOO=' "$DIST_DIR/.secrets"              && CONT_FOO=1 || CONT_FOO=0

assert "container .secrets has no _-prefix lines" $([ "$CONT_DOTENV_LEAK" = 0 ] && echo 1 || echo 0)
assert "container .secrets.d/ has no _-prefix files" $([ "$CONT_FILE_LEAK" = 0 ] && echo 1 || echo 0)
assert "container .secrets keeps FOO=bar" "$CONT_FOO"

log() { echo "  [test] $*"; }

# ─── TEST 3: home-manager engine ───
echo ""
echo "─── Home-manager engine ───"

HM_SRC="$WORK/hm/src"
HM_DIST="$WORK/hm/dist"
mkdir -p "$HM_SRC" "$HM_DIST"
cp "$WORK/secrets.yaml" "$HM_SRC/secrets.yaml"

if ! command -v yq >/dev/null 2>&1; then
  assert "HM engine (yq missing — SKIPPED)" 0
else
  bash -c '
    set -e
    export SRC_DIR="$1"
    export DIST_DIR="$2"
    log() { :; }
    . "$3"
    step_secrets
  ' _ "$HM_SRC" "$HM_DIST" "$SCRIPTS_DIR/cloud-ship-nix-homemanager-step-secrets-decrypt.sh" >/dev/null

  grep -q '^_' "$HM_DIST/.secrets"                    && HM_DOTENV_LEAK=1 || HM_DOTENV_LEAK=0
  ls "$HM_DIST/.secrets.d" 2>/dev/null | grep -q '^_' && HM_FILE_LEAK=1 || HM_FILE_LEAK=0
  grep -q '^FOO=' "$HM_DIST/.secrets"                 && HM_FOO=1 || HM_FOO=0

  assert "HM .secrets has no _-prefix lines" $([ "$HM_DOTENV_LEAK" = 0 ] && echo 1 || echo 0)
  assert "HM .secrets.d/ has no _-prefix files" $([ "$HM_FILE_LEAK" = 0 ] && echo 1 || echo 0)
  assert "HM .secrets keeps FOO=bar" "$HM_FOO"
fi

# ─── TEST 4: 3_secrets viewer engine ───
echo ""
echo "─── Viewer engine ───"

VIEW_SRC="$WORK/viewer/src/builds"
VIEW_DIST="$WORK/viewer/dist"
mkdir -p "$VIEW_SRC" "$VIEW_DIST"
cp "$WORK/secrets.yaml" "$VIEW_SRC/testfixture-secrets.yaml"

VIEWER_ENGINE="$(cd "$CLOUD_ROOT/../3_secrets/src/engines" && pwd)/secrets.sh"
(
  set +e
  mkdir -p "$WORK/viewer/src/engines"
  cp "$VIEWER_ENGINE" "$WORK/viewer/src/engines/secrets.sh"
  bash "$WORK/viewer/src/engines/secrets.sh" decrypt >/dev/null 2>&1
)

dotenv="$VIEW_DIST/testfixture-secrets.secrets"
json_out="$VIEW_DIST/testfixture-secrets.json.secrets"
if [ -f "$dotenv" ] && [ -f "$json_out" ]; then
  grep -q '^FOO=' "$dotenv"                             && VIEW_FOO=1 || VIEW_FOO=0
  grep -q '^_credentials\.x\.password=' "$dotenv"       && VIEW_CRED=1 || VIEW_CRED=0
  jq -e '._credentials.x.password == "p"' "$json_out" >/dev/null 2>&1 && VIEW_JSON=1 || VIEW_JSON=0
  assert "viewer .secrets has FOO=bar" "$VIEW_FOO"
  assert "viewer .secrets has _credentials.x.password (flattened)" "$VIEW_CRED"
  assert "viewer .json.secrets has nested _credentials.x.password" "$VIEW_JSON"
else
  assert "viewer engine produced .secrets + .json.secrets" 0
fi

# ─── TEST 5: mail-mcp-style boot ───
echo ""
echo "─── mail-mcp-style boot (sops | jq | eval) ───"
unset FOO _credentials _credentials__x__password 2>/dev/null || true
ENV_DUMP=$(
  set -a
  # shellcheck disable=SC2046
  eval "$(
    sops -d --output-type json "$WORK/secrets.yaml" \
      | jq -r 'to_entries[] | select(.key | startswith("_") | not) |
          "\(.key)=\(.value | tostring | @sh)"'
  )"
  set +a
  env | grep -E '^(FOO|_credentials|_)' || true
)

echo "$ENV_DUMP" | grep -q '^FOO=bar'      && MM_FOO=1 || MM_FOO=0
echo "$ENV_DUMP" | grep -q '^_credentials' && MM_LEAK=1 || MM_LEAK=0

assert "mail-mcp eval exports FOO=bar" "$MM_FOO"
assert "mail-mcp eval does NOT export _credentials" $([ "$MM_LEAK" = 0 ] && echo 1 || echo 0)

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Roundtrip: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
