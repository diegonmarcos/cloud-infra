#!/usr/bin/env bash
# Test: cloud-ship-detect-dist-consumers.sh ships what changed and only what changed.
#
# The assertion with value here is not "the script runs" — it is that BOTH directions
# hold on real git history: a commit that touches a service's own declaration still
# deploys it, and a commit that touches only the fleet-wide broadcast registry does not.
# The fleet has been bitten from both sides. Getting the first wrong ships a green run
# that deployed nothing (c3-public-api's mail fix, 2026-08-24). Getting the second wrong
# redeployed 43 services on oci-apps for two unrelated MCP registrations (96e362760,
# 2026-09-05) — cloud-ide among them.
#
# Each case is built as a real commit in a throwaway repo laid out like cloud-infra, so
# the script is exercised through `git show` / `git diff` exactly as it is in CI, not
# through a mock of them.
set -eu

REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
DETECT="$REPO_ROOT/1_cicd/src/scripts/cloud-ship-detect-dist-consumers.sh"
[ -f "$DETECT" ] || { echo "::error::$DETECT not found"; exit 1; }

FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT
FAILED=0

# ── A cloud-infra-shaped fixture ────────────────────────────────────────────────
# reader:  binds the registry (`svc = container.services;`) the way cloud-infra-mcp does
# quiet:   never binds it, the way user-prod_code-server (cloud-ide) does
build_fixture() {
  rm -rf "$FIXTURE"; mkdir -p "$FIXTURE"
  cd "$FIXTURE"
  git init -q .
  git config user.email t@t; git config user.name t

  mkdir -p 9_others 1_cloud-configs/dist a_solutions/svc_reader/src a_solutions/svc_quiet/src
  cp "$REPO_ROOT/9_others/ship-dist-broadcast-blocks.json" 9_others/

  for n in reader quiet; do
    cat > "1_cloud-configs/dist/build-$n.json" <<JSON
{
  "service": "$n",
  "container": { "image": "base:1", "port": 8000 },
  "services": { "peer-a": { "ip": "10.0.0.1", "ports": { "app": 1000 } } }
}
JSON
    ln -s "../../../1_cloud-configs/dist/build-$n.json" "a_solutions/svc_$n/src/build-$n.json"
  done

  cat > a_solutions/svc_reader/src/compose.nix <<'NIX'
{ buildJson, container }:
let svc = container.services;
in { services.reader = { image = buildJson.container.image; peer = svc."peer-a".ip; }; }
NIX
  cat > a_solutions/svc_quiet/src/compose.nix <<'NIX'
{ buildJson, container }:
{ services.quiet = { image = buildJson.container.image; }; }
NIX

  git add -A >/dev/null; git commit -qm base
  cd - >/dev/null
}

# Run the detector over the last commit and return the decision line for one service.
decision_for() {  # $1 = service dir
  ( cd "$FIXTURE" && bash "$DETECT" HEAD~1 HEAD 2>/dev/null ) | awk -F'\t' -v s="$1" '$2==s {print; exit}'
}

check() {  # $1 = label   $2 = expected decision   $3 = actual line
  local got; got=$(printf '%s' "$3" | cut -f1)
  if [ "$got" = "$2" ]; then
    echo "  ok   $1 → $2"
  else
    echo "::error::$1 — expected $2, got '${got:-<no decision emitted>}'"
    echo "         full line: ${3:-<none>}"
    FAILED=1
  fi
}

# ── 1. A service's OWN declaration changed → must still deploy ───────────────────
build_fixture
cd "$FIXTURE"
jq '.container.image = "base:2"' 1_cloud-configs/dist/build-quiet.json > t && mv t 1_cloud-configs/dist/build-quiet.json
git commit -qam "bump svc_quiet's own image"
cd - >/dev/null
LINE=$(decision_for svc_quiet)
check "own declaration changed (image bump)" SHIP "$LINE"

# ── 2. Broadcast-only change, consumer never reads the registry → must NOT deploy ─
# This is the cloud-ide case, reproduced: a peer appears in the fleet registry and is
# stamped into every build-*.json, including one whose compose.nix cannot see it.
build_fixture
cd "$FIXTURE"
for n in reader quiet; do
  jq '.services["peer-new"] = { "ip": "10.0.0.9", "ports": { "app": 3110 } }' \
     "1_cloud-configs/dist/build-$n.json" > t && mv t "1_cloud-configs/dist/build-$n.json"
done
git commit -qam "register peer-new fleet-wide"
cd - >/dev/null
LINE=$(decision_for svc_quiet)
check "broadcast-only, consumer never binds registry" SKIP "$LINE"

# ── 3. Same commit, consumer that DOES read the registry → must deploy ───────────
LINE=$(decision_for svc_reader)
check "broadcast-only, consumer binds registry" SHIP "$LINE"

# ── 4. Declaration data absent → must fail OPEN, never suppress ──────────────────
cd "$FIXTURE"; rm -f 9_others/ship-dist-broadcast-blocks.json; cd - >/dev/null
LINE=$(decision_for svc_quiet)
check "broadcast declaration missing (fail open)" SHIP "$LINE"

[ "$FAILED" -eq 0 ] || exit 1
echo "PASS: dist-consumer detection ships what changed and only what changed"
