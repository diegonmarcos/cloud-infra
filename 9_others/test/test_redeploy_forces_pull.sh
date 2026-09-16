#!/bin/sh
# The split ship.yml `deploy` job (SHIP_MODE=deploy -> `redeploy` verb) must PULL
# the image the `build` job just pushed, never serve a stale local :latest.
#
# Bug (2026-08-26, run 32954725752): redeploy runs no step_docker, so
# DOCKER_IMAGE_CHANGED was unset; step_compose's pull gate then chose
# `--pull missing` and the box recreated cloud-cgc-*-mcp from a cached 0.12.2
# :latest even though a 0.22 image was on GHCR — green run, wrong binary.
#
# Two checks: (1) the redeploy verb exports DOCKER_IMAGE_CHANGED before deploy;
# (2) EXECUTED — the exact pull-gate from step-deploy-compose.sh yields
# `--pull always` when DOCKER_IMAGE_CHANGED is set and `--pull missing` when only
# CONFIG_CHANGED is (the state redeploy was in).
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ENGINE="$ROOT/1_cicd/src/scripts/cloud-ship-container-engine.sh"
DEPLOY="$ROOT/1_cicd/src/scripts/cloud-ship-container-step-deploy-compose.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; \
       else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }

# (1) redeploy exports DOCKER_IMAGE_CHANGED on the same line-region as its pipeline.
redeploy_arm=$(awk '/^    redeploy\)/{f=1} f{print} f&&/;;/{exit}' "$ENGINE")
ck "redeploy exports DOCKER_IMAGE_CHANGED" \
   "$(printf '%s\n' "$redeploy_arm" | grep -c 'export DOCKER_IMAGE_CHANGED')" "1"
ck "redeploy still runs the deploy pipeline (step_compose + step_health)" \
   "$(printf '%s\n' "$redeploy_arm" | grep -c 'step_deploy; step_compose; step_health')" "1"
ck "the export precedes the deploy pipeline line" \
   "$(printf '%s\n' "$redeploy_arm" | awk '/export DOCKER_IMAGE_CHANGED/{e=NR} /step_compose/{c=NR} END{print (e && c && e < c) ? "yes" : "no"}')" "yes"

# (2) execute the real gate on a stub. Extract the if/elif/else block that sets
# _PULL_POLICY and run it under the two variable states.
awk '/# ── Recreate \/ pull policy: decoupled/{f=1} f{print} f&&/^    fi$/{exit}' "$DEPLOY" > "$T/gate.sh"
ck "pull gate extracted" "$(grep -c '_PULL_POLICY' "$T/gate.sh")" "$(grep -c '_PULL_POLICY' "$T/gate.sh" 2>/dev/null || echo 0)"
run_gate() { # $1 = shell snippet setting the vars -> prints "$_PULL_POLICY|$COMPOSE_PULL_FIRST"
  ( eval "$1"; . "$T/gate.sh"; printf '%s|%s' "$_PULL_POLICY" "$COMPOSE_PULL_FIRST" )
}
ck "image changed -> pull always"                 "$(run_gate 'DOCKER_IMAGE_CHANGED=1; CONFIG_CHANGED=1')" "--pull always|true"
ck "config-only (the redeploy bug state) -> missing" "$(run_gate 'CONFIG_CHANGED=1')"                        "--pull missing|false"
ck "both unset (manual compose) -> pull always"    "$(run_gate ':')"                                         "--pull always|true"

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
