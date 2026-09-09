#!/bin/sh
# A Ship run that detected services to ship and then did not ship them must be RED.
#
# 2026-09-09, run 34334421319: detect logged "detect: a_solutions
# af913083..902bbba9" and "VMs: 1 - oci-apps", Build -> oci-apps pushed the
# my-ai_claude-api image successfully, and Deploy -> oci-apps then ran ZERO
# steps. It was evicted from the fleet-wide ship-wg-runner concurrency group
# (GitHub keeps exactly one pending entry per group, so the next
# containers-push displaces the one waiting) while a wedged cgc-db run held
# the slot. The run ended "cancelled": grey in the UI, no notification,
# indistinguishable from a human pressing cancel. The commit sat in git, the
# image sat in GHCR, and oci-apps kept serving three-hour-old code behind a
# Ship page that looked idle.
#
# The gate turns that silence into a failure. `always()` is load-bearing: a job
# cancelled by concurrency does not cancel the run, which is the only reason a
# downstream job can observe the eviction at all.
set -eu
REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; \
       else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }

# ── Structure: the gate exists and is wired to see a cancelled deploy ──
for f in 1_cicd/src/cicd/ship.yml .github/workflows/ship.yml; do
  Y="$REPO_ROOT/$f"
  ck "$f: deploy-gate job declared" \
     "$(python3 -c 'import yaml,sys; print("deploy-gate" in yaml.safe_load(open(sys.argv[1]))["jobs"])' "$Y")" "True"
  # Without detect in needs its outputs are not guaranteed to be readable, and
  # without deploy the gate has no result to judge.
  ck "$f: deploy-gate needs detect, build and deploy" \
     "$(python3 -c 'import yaml,sys; print(sorted(yaml.safe_load(open(sys.argv[1]))["jobs"]["deploy-gate"]["needs"]))' "$Y")" \
     "['build', 'deploy', 'detect']"
  ck "$f: deploy-gate runs unconditionally (always())" \
     "$(python3 -c 'import yaml,sys; print("always()" in yaml.safe_load(open(sys.argv[1]))["jobs"]["deploy-gate"]["if"])' "$Y")" "True"
done

# ── Guard: a registered service resolving to zero VMs must not report success ──
for f in 1_cicd/src/cicd/ship.yml .github/workflows/ship.yml; do
  Y="$REPO_ROOT/$f"
  ck "$f: zero-VM guard fails on a registered service" \
     "$(grep -c 'the service→vm mapping in build-gha.json is broken' "$Y" || true)" "1"
  ck "$f: zero-VM guard stays green for a non-service dir" \
     "$(grep -c '::notice::changed but not a deployable container service' "$Y" || true)" "1"
done

# ── Behaviour: run the gate's own script, as shipped ──
# Extracted from the generated workflow rather than restated here, so the test
# cannot drift into asserting a copy of the logic that no longer ships.
GATE="$(mktemp)"
python3 -c 'import yaml,sys; sys.stdout.write(yaml.safe_load(open(sys.argv[1]))["jobs"]["deploy-gate"]["steps"][0]["run"])' \
  "$REPO_ROOT/.github/workflows/ship.yml" > "$GATE"
MATRIX='{"include":[{"vm":"oci-apps","changed_dirs":"user-ai_my-ai_claude-api"}]}'
export MATRIX BUILD_RESULT=success

run_gate() { DEPLOY_RESULT="$1" sh "$GATE" >"$GATE.out" 2>&1; }

DEPLOY_RESULT=success run_gate success && rc=0 || rc=$?
ck "gate passes when the deploy succeeded" "$rc" "0"

run_gate cancelled && rc=0 || rc=$?
ck "gate FAILS on an evicted (cancelled) deploy" "$rc" "1"
ck "gate names the undeployed service" \
   "$(grep -c 'user-ai_my-ai_claude-api' "$GATE.out" || true)" "1"
ck "gate points at unjam-ship for a cancelled deploy" \
   "$(grep -c 'unjam-ship' "$GATE.out" || true)" "1"

# skipped is what a build failure leaves behind; the services are still absent
# from the fleet, so the gate must be just as loud.
run_gate skipped && rc=0 || rc=$?
ck "gate FAILS when deploy was skipped" "$rc" "1"

rm -f "$GATE" "$GATE.out"
echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
