#!/usr/bin/env bash
# Test: a b_infra/** commit must carry the required deploy-authorization
# marker before ship-home-manager.yml will deploy to any VM (#414).
#
# #414 (2026-09-16): ANY commit touching b_infra/** shipped home-manager to
# ALL FOUR VMs unconditionally, recreating the agent containers on oci-apps
# and killing every running headless agent mid-task. This test guards the
# fail-closed gate added to close that hole.
#
# It asserts two things:
#   1. The gate script (cloud-ship-b-infra-deploy-authorization.sh) returns
#      the right verdict for every trigger x marker combination — a live,
#      executable proof of the logic this whole fix rests on.
#   2. The source workflow (1_cicd/src/cicd/ship-home-manager.yml) actually
#      WIRES the gate, so the gate script cannot be a dead artifact.
#
# Source-level where possible: the workflow assertions scan
# 1_cicd/src/cicd/ship-home-manager.yml (the template), not the generated
# .github/workflows copy, so they fail the moment a new workflow forgets the
# gate, before build.sh regenerates dist.
set -eu

# Repo root by upward search — this file exists at both 9_others/test/ and
# 9_others/dist/test/ (generated), which sit at different depths.
ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
GATE="$ROOT/1_cicd/src/scripts/cloud-ship-b-infra-deploy-authorization.sh"
WORKFLOW="$ROOT/1_cicd/src/cicd/ship-home-manager.yml"

# The marker must match the one wired into the workflow. Reject drift.
MARKER="[deploy-fleet]"
if ! grep -qF "B_INFRA_DEPLOY_MARKER: \"$MARKER\"" "$WORKFLOW"; then
    echo "::error::$WORKFLOW does not define B_INFRA_DEPLOY_MARKER = \"$MARKER\" — gate and workflow out of sync"
    exit 1
fi

[ -f "$GATE" ] || { echo "::error::gate script missing: $GATE"; exit 1; }
[ -f "$WORKFLOW" ] || { echo "::error::workflow missing: $WORKFLOW"; exit 1; }

FAIL=0
check() {
    # check <label> <expected_rc> <cmd...>
    local label="$1" expected="$2"; shift 2
    local rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq "$expected" ]; then
        printf '  ok         %-45s rc=%d (expected %d)\n' "$label" "$rc" "$expected"
    else
        printf '  FAIL       %-45s rc=%d (expected %d)\n' "$label" "$rc" "$expected"
        FAIL=1
    fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fixture payloads
cat > "$TMP/push-no-marker.json" <<'EOF'
{"commits":[{"id":"abc123","message":"fix(watchdog): scope prunes","added":["b_infra/_shared/vm-pilot/src/x.nix"],"modified":[],"removed":[]}]}
EOF
cat > "$TMP/push-marker.json" <<'EOF'
{"commits":[{"id":"abc123","message":"fix(watchdog): scope prunes [deploy-fleet]","added":["b_infra/_shared/vm-pilot/src/x.nix"],"modified":[],"removed":[]}]}
EOF
cat > "$TMP/push-marker-second-commit.json" <<'EOF'
{"commits":[
  {"id":"abc123","message":"fix(watchdog): scope prunes","added":["b_infra/x.nix"],"modified":[],"removed":[]},
  {"id":"def456","message":"docs: unrelated [deploy-fleet]","added":["README.md"],"modified":[],"removed":[]}
]}
EOF
cat > "$TMP/push-no-binfra.json" <<'EOF'
{"commits":[{"id":"abc123","message":"docs: unrelated","added":["README.md"],"modified":[],"removed":[]}]}
EOF
# GitHub's push payload uses NULL (not []) for a commit's added/removed when it
# only modified files — the real shape of the first post-#414 b_infra push
# (74c17d50d) that crashed the gate's jq. Regression pair for #447.
cat > "$TMP/push-null-arrays-no-marker.json" <<'EOF'
{"commits":[{"id":"abc123","message":"fix(watchdog): prune scopes","added":null,"modified":["b_infra/_shared/vm-pilot/src/watchdog.nix","9_others/test-registry.json"],"removed":null}]}
EOF
cat > "$TMP/push-null-arrays-marker.json" <<'EOF'
{"commits":[{"id":"abc123","message":"fix(watchdog): prune scopes [deploy-fleet]","added":null,"modified":["b_infra/_shared/vm-pilot/src/watchdog.nix"],"removed":null}]}
EOF
cat > "$TMP/dispatch.json" <<'EOF'
{"ref":"refs/heads/main"}
EOF
cat > "$TMP/workflow_run-no-marker.json" <<'EOF'
{"workflow_run":{"head_commit":{"message":"ci(gen-configs): refresh dist from trigger"}}}
EOF
cat > "$TMP/workflow_run-marker.json" <<'EOF'
{"workflow_run":{"head_commit":{"message":"ci(gen-configs): refresh dist from trigger [deploy-fleet]"}}}
EOF

echo "Gate script verdicts (marker: $MARKER)"
export GATE MARKER TMP B_INFRA_DEPLOY_MARKER="$MARKER"

check "push, b_infra, no marker → REFUSE(1)" 1 \
    bash "$GATE" push "$TMP/push-no-marker.json"
check "push, b_infra, marker → allow(0)" 0 \
    bash "$GATE" push "$TMP/push-marker.json"
check "push, marker on unrelated commit → REFUSE(1)" 1 \
    bash "$GATE" push "$TMP/push-marker-second-commit.json"
check "push, no b_infra change → allow(0)" 0 \
    bash "$GATE" push "$TMP/push-no-binfra.json"
check "push, modify-only commit (null arrays), no marker → REFUSE(1)" 1 \
    bash "$GATE" push "$TMP/push-null-arrays-no-marker.json"
check "push, modify-only commit (null arrays), marker → allow(0)" 0 \
    bash "$GATE" push "$TMP/push-null-arrays-marker.json"
check "dispatch, no confirm → REFUSE(1)" 1 \
    bash "$GATE" workflow_dispatch "$TMP/dispatch.json" "false"
check "dispatch, confirm=true → allow(0)" 0 \
    bash "$GATE" workflow_dispatch "$TMP/dispatch.json" "true"
check "workflow_run, no marker → REFUSE(1)" 1 \
    bash "$GATE" workflow_run "$TMP/workflow_run-no-marker.json"
check "workflow_run, marker → allow(0)" 0 \
    bash "$GATE" workflow_run "$TMP/workflow_run-marker.json"
check "unknown event → REFUSE(1)" 1 \
    bash "$GATE" pull_request "$TMP/dispatch.json"

echo "Workflow wiring (fail-closed gate present in source)"
check "workflow names the Gate step" 0 bash -c \
    "grep -qF 'name: Gate (deploy-authorization + manual VM filter + path-relevance)' '$WORKFLOW'"
check "workflow references the gate script" 0 bash -c \
    "grep -qF 'cloud-ship-b-infra-deploy-authorization.sh' '$WORKFLOW'"
check "push trigger requires the gate" 0 bash -c \
    "grep -qE 'bash \"\\\$AUTH\" push \"\\\$GITHUB_EVENT_PATH\"' '$WORKFLOW'"
check "dispatch path requires confirm input" 0 bash -c \
    "grep -qE 'confirm_fleet_deploy' '$WORKFLOW'"
check "workflow_run path requires the marker" 0 bash -c \
    "grep -qE 'bash \"\\\$AUTH\" workflow_run' '$WORKFLOW'"

if [ "$FAIL" -eq 1 ]; then
    echo
    echo "::error::b_infra deploy-authorization gate test FAILED."
    echo "A b_infra change without the required marker ('$MARKER') must never deploy."
    exit 1
fi

echo
echo "OK — every trigger refuses without the marker and allows with it; the workflow wires the gate."
