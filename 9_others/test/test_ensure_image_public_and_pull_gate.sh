#!/usr/bin/env bash
# Tester for the 2026-07-11 dagu-outage engine fixes:
#
#   1. _ensure_image_public (cloud-ship-container-step-build-docker.sh) —
#      VERIFIES a GHCR package is anonymously pullable BEFORE deploy, retrying
#      to ride out GHCR propagation lag on a fresh push (GitHub has no API to
#      flip visibility, so it does NOT try). Returns NON-ZERO (fatal) when the
#      package is genuinely private — so the deploy aborts before the
#      destructive compose instead of tearing down a running container for an
#      image the VM can't pull.
#
#   2. compose pull-gate (cloud-ship-container-step-deploy-compose.sh) —
#      when refreshing to a new image, the generated deploy script pulls (or
#      confirms local cache) BEFORE `down`, and aborts before teardown when
#      the image is neither pullable nor cached.
#
# Sources the REAL engine file so the tested logic stays 1:1 with production;
# network (curl) + gh + sleep are stubbed to drive deterministic scenarios.
set -euo pipefail

# This tester used to live beside the step scripts in gha/scripts/, so it
# resolved them from its own directory. It moved to test/ when the suite was
# consolidated in one place — resolve the steps from the scripts dir instead.
HERE="$(cd "$(dirname "$0")" && pwd)"
STEPS="$(cd "$HERE/../../1_cicd/src/scripts" && pwd)"
DOCKER_STEP="$STEPS/cloud-ship-container-step-build-docker.sh"
DEPLOY_STEP="$STEPS/cloud-ship-container-step-deploy-compose.sh"

pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ok: $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL: $1"; }

# _ensure_image_public has a documented early-return: when GITHUB_TOKEN is set
# the VM pulls via that token, so a private package is a warning rather than a
# fatal. Cases 2/4 below assert the FATAL path, which means the ambient
# environment must not leak a token in — it is set both on GHA runners and in
# this repo's dev containers, which is why this tester passed locally for
# whoever wrote it and failed everywhere else.
unset GITHUB_TOKEN

# ── Stubs (must exist before sourcing so the helper closes over them) ──
log()       { :; }
log_warn()  { :; }
log_error() { :; }
sleep()     { :; }                       # no real backoff waits in the test
# gh: no-op "flip" — success/failure is decided purely by the curl stub's
# view of visibility, so this just has to not error.
gh()        { return 0; }

# curl stub: drives pullability from $PULLABLE_STATE. The manifest-call
# counter lives in a FILE ($CURL_CALLS_FILE) because _eip_pullable invokes
# curl inside $(...) command substitution (a subshell) — a shell variable
# would never propagate the increment back out.
#   public         → token ok + manifest 200
#   private        → token ok + manifest 401 (forever)
#   flip_on_2      → 401 on the first two manifest checks, 200 from the third
#                    (simulates a fresh PUBLIC package becoming pullable once
#                     GHCR propagation completes, after a retry)
CURL_CALLS_FILE="$(mktemp)"
echo 0 > "$CURL_CALLS_FILE"
trap 'rm -f "$CURL_CALLS_FILE"' EXIT
curl() {
    local args="$*"
    case "$args" in
        *"/token"*) printf '{"token":"stub-token"}' ;;   # token request
        *"/manifests/"*)                                 # manifest HEAD (-w %{http_code})
            local n; n=$(( $(cat "$CURL_CALLS_FILE") + 1 )); echo "$n" > "$CURL_CALLS_FILE"
            case "${PULLABLE_STATE:-private}" in
                public)     printf '200' ;;
                flip_on_2)  [ "$n" -ge 3 ] && printf '200' || printf '401' ;;
                *)          printf '401' ;;
            esac ;;
        *) : ;;
    esac
}

# Source ONLY the helper (top-level function) — the file defines
# _ensure_image_public + step_docker; sourcing binds both without executing.
# shellcheck disable=SC1090
source "$DOCKER_STEP"

echo "── _ensure_image_public contract ──"

# 1) Already public → returns 0, no flip loop needed.
echo 0 > "$CURL_CALLS_FILE"; PULLABLE_STATE=public
if _ensure_image_public diegonmarcos already-public-pkg; then
    ok "public package → success (exit 0)"
else
    bad "public package should return 0"
fi

# 2) Private and un-flippable → returns NON-ZERO (fatal) after retries.
echo 0 > "$CURL_CALLS_FILE"; PULLABLE_STATE=private
if _ensure_image_public diegonmarcos stuck-private-pkg; then
    bad "un-pullable package must return non-zero (fatal), got 0"
else
    ok "un-pullable package → fatal (non-zero) — deploy will abort before teardown"
fi

# 3) Fresh public package pullable after propagation retry → returns 0.
echo 0 > "$CURL_CALLS_FILE"; PULLABLE_STATE=flip_on_2
if _ensure_image_public diegonmarcos flips-after-retry-pkg; then
    ok "package pullable after propagation retry → success (exit 0)"
else
    bad "package pullable after retry should return 0"
fi

echo "── compose pull-gate wiring (deploy-compose source) ──"

# The pull-gate must (a) exist for the pull-first path and (b) place its
# abort (`exit 1`) BEFORE the `down` line — otherwise a running container is
# torn down for an image that can't be obtained.
if grep -q 'refusing to tear down running container' "$DEPLOY_STEP"; then
    ok "abort-before-teardown guard present"
else
    bad "abort-before-teardown guard missing"
fi

# Custom-compose branch: the PULL_GATE here-doc's `exit 1` precedes the
# `down --remove-orphans` emit line.
gate_ln=$(grep -n 'refusing to tear down running container(s) for an unobtainable image' "$DEPLOY_STEP" | head -1 | cut -d: -f1)
down_ln=$(grep -n "docker compose .*down --remove-orphans .*|| true'" "$DEPLOY_STEP" | head -1 | cut -d: -f1)
if [ -n "$gate_ln" ] && [ -n "$down_ln" ] && [ "$gate_ln" -lt "$down_ln" ]; then
    ok "custom-compose gate (line $gate_ln) precedes down (line $down_ln)"
else
    bad "custom-compose gate must precede down (gate=$gate_ln down=$down_ln)"
fi

# up must not re-pull on the cache-fallback path (always→missing swap present).
if grep -q 'COMPOSE_UP_FLAGS/--pull always/--pull missing' "$DEPLOY_STEP"; then
    ok "up pull-policy downgraded to missing after explicit gated pull"
else
    bad "up should use --pull missing after the gate pulls explicitly"
fi

echo ""
echo "═══════════════════════════════════════"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ] || exit 1
