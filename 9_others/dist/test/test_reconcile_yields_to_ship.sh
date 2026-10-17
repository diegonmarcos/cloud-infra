#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_reconcile_yields_to_ship.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# The reconcile must not queue on ship-wg-runner while a Ship is in flight.
#
# A Ship's per-VM deploy jobs re-enter the fleet-wide FIFO one after another
# (max-parallel 1). A reconcile that queues meanwhile lands AHEAD of the Ship's next
# deploy job, and cancelling it makes `requeue` dispatch another one (Ship
# 38998754151, 2026-10-17: oci-analytics waited ~20 min behind a scheduled reconcile).
# So the reconcile job is gated on a probe that itself holds NO lock:
#   1. yield-to-ship exists, declares NO concurrency group, and is bounded;
#   2. reconcile `needs` it and skips when a Ship is active -- but a human
#      workflow_dispatch always runs;
#   3. the existing #840 loop bound on workflow_run is still in the condition;
#   4. requeue still hangs off reconcile only (a skipped reconcile re-queues nothing).
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(_d="$SCRIPT_DIR"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
WF="$REPO_ROOT/1_cicd/src/cicd/ship-reconcile.yml"
[ -f "$WF" ] || { echo "FAIL: $WF missing"; exit 1; }
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1: expected '$3', got '$2'"; fi; }

out="$(python3 -I - "$WF" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
j = d["jobs"]
y = j.get("yield-to-ship", {})
r = j.get("reconcile", {})
cond = " ".join(str(r.get("if", "")).split())
needs = r.get("needs"); needs = [needs] if isinstance(needs, str) else (needs or [])
rq = j.get("requeue", {}).get("needs")
print("probe_exists=%s" % bool(y))
print("probe_no_group=%s" % ("concurrency" not in y))
print("probe_bounded=%s" % (isinstance(y.get("timeout-minutes"), int) and y["timeout-minutes"] <= 5))
print("reconcile_needs_probe=%s" % ("yield-to-ship" in needs))
print("skips_when_active=%s" % ("needs.yield-to-ship.outputs.ship_active != 'true'" in cond))
print("dispatch_always_runs=%s" % ("github.event_name == 'workflow_dispatch'" in cond))
print("loop_bound_kept=%s" % all(s in cond for s in ("workflow_run.name == 'Ship'", "conclusion == 'cancelled'", "event != 'workflow_dispatch'")))
print("requeue_on_reconcile_only=%s" % (rq == "reconcile"))
PY
)"
for k in probe_exists probe_no_group probe_bounded reconcile_needs_probe skips_when_active dispatch_always_runs loop_bound_kept requeue_on_reconcile_only; do
  ck "$k" "$(printf '%s\n' "$out" | sed -n "s/^$k=//p")" "True"
done
echo ""; echo "  passed $pass, failed $fail"
[ "$fail" -eq 0 ] || exit 1
