#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_wg_group_lock_bounded.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# The fleet has ONE WireGuard identity (10.0.0.200), so every WG-holding job
# shares ONE concurrency group, ship-wg-runner, with cancel-in-progress:false.
# GitHub keeps exactly one PENDING entry per group, so a job that queues behind
# a wedged holder does not wait in line — it DISPLACES the one already waiting,
# which then reports as a grey "cancelled" with no notification.
#
# That makes the time any single job may hold this group a fleet-wide outage
# budget, not a per-job detail. Two failures on 2026-09-09 proved it:
#
#   1. cgc-db.yml declared the group at WORKFLOW level, so its index matrix —
#      which reaches only GHCR and openrouter.ai and never brings WireGuard up —
#      held the deploy lock under a 330-minute ceiling. Run 34329534560 was still
#      running 91 minutes after all eight siblings finished, with a Deploy
#      pending behind it and nothing running.
#   2. unjam-ship.yml, the watchdog for exactly this, issued a graceful cancel,
#      got HTTP 202, reported SUCCESS, and the run stayed in_progress for at
#      least five more minutes. A graceful cancel is a request a wedged runner
#      may ignore, and a wedged runner is the only case the unjammer exists for.
#
# So this file asserts two things that would each have caught that day outright:
# no job in the group may declare a ceiling above CEILING_MINUTES, and the
# unjammer must escalate to force-cancel AND verify the run really died before
# reporting success.
#
# Usage: sh 9_others/test/test_wg_group_lock_bounded.sh
set -eu

REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
GROUP="ship-wg-runner"

# The maximum minutes any one job may hold the fleet's deploy lock.
#
# 240 is set by the single slowest legitimate holder, cgc-db-index.yml's
# restore-all: run 32754160748 measured the pub surface alone at ~108min and pvt
# was still alive at 65min under a 180-min ceiling, and the two surfaces run
# sequentially in one job — so ~220min is the real number and 240 clears it with
# ~10% headroom. Every other job in the group is <= 90. Lower this as the arm64
# emulation / re-pull debt behind restore-all's runtime lands; do NOT raise it
# without a measurement, because this is an outage budget.
CEILING_MINUTES=240

pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; \
       else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }

echo "── ship-wg-runner lock is bounded and the unjammer can actually unjam ──"

# ── Assertion 1: no job in the group may outlive the ceiling ──
#
# "Jobs in the group" is resolved, not grepped. A workflow-level `concurrency`
# puts EVERY job of the run in the group, including the jobs of any reusable
# workflow it calls — which is exactly how an index job that needs no mesh came
# to hold the deploy lock. So the resolver follows `uses: ./.github/workflows/X`
# into X whenever the caller holds the group at workflow level, and otherwise
# takes only the jobs declaring it themselves.
#
# A job with NO timeout-minutes is a failure, not a pass: GitHub's default is
# 360 minutes, worse than the 340 this test was written to outlaw.
RESOLVER="$REPO_ROOT/9_others/test/wg_group_jobs.py"
for d in 1_cicd/src/cicd .github/workflows; do
  OUT="$(python3 "$RESOLVER" "$REPO_ROOT/$d" "$GROUP")"
  # Every offending job, one per line: "workflow job timeout"
  OVER="$(echo "$OUT" | awk -v c="$CEILING_MINUTES" '$3 == "none" || $3+0 > c')"
  ck "$d: every $GROUP job declares a timeout <= ${CEILING_MINUTES}m" \
     "$(echo "$OVER" | grep -c . || true)" "0"
  [ -z "$OVER" ] || echo "$OVER" | sed 's/^/       over ceiling: /'
  # Guard the guard: if the resolver finds no jobs at all the assertion above
  # is vacuously true, which is how this kind of test rots into decoration.
  ck "$d: resolver actually found $GROUP jobs" \
     "$(echo "$OUT" | grep -c . || true)" \
     "$(echo "$OUT" | grep -c . || true)"
  [ "$(echo "$OUT" | grep -c . || true)" -gt 0 ] || \
    { fail=$((fail+1)); echo "  FAIL $d: resolver found ZERO jobs in $GROUP — assertion was vacuous"; }
done

# ── Assertion 2: the unjammer escalates and verifies ──
for f in 1_cicd/src/cicd/unjam-ship.yml .github/workflows/unjam-ship.yml; do
  Y="$REPO_ROOT/$f"
  # Extract the step's script as shipped rather than restating it here, so the
  # test cannot drift into asserting a copy of logic that no longer runs.
  S="$(python3 -c 'import yaml,sys; sys.stdout.write(yaml.safe_load(open(sys.argv[1]))["jobs"]["unjam"]["steps"][0]["run"])' "$Y")"

  # Anchored to the actual call the step makes, not a bare mention: the
  # ::error:: message also names force-cancel and hands the operator a
  # copy-pasteable `gh api ... /force-cancel`, so a looser pattern would pass
  # on a step that merely DESCRIBES the escalation without performing it —
  # exactly the decoration this file exists to avoid.
  ck "$f: POSTs to the force-cancel endpoint" \
     "$(echo "$S" | grep -c -- 'gh_api -X POST "\$api/actions/runs/\$id/force-cancel"' || true)" "1"
  ck "$f: tries the graceful cancel first" \
     "$(echo "$S" | grep -c -- 'gh_api -X POST "\$api/actions/runs/\$id/cancel"' || true)" "1"
  ck "$f: waits a bounded grace period before escalating" \
     "$(echo "$S" | grep -c 'sleep "\$GRACE_SECONDS"' || true)" "1"
  # The part that makes it trustworthy: re-read status AFTER cancelling and
  # fail loudly if the run is still alive. Reporting green while the group is
  # still held converts an outage into a silent one.
  ck "$f: re-reads run status after cancelling" \
     "$(echo "$S" | grep -c 'jq -r .\.status' || true)" "1"
  ck "$f: fails loudly when a run survives the force-cancel" \
     "$(echo "$S" | awk '/::error::.*still/{f=1} f&&/^ *exit 1/{print "y";exit}' || true)" "y"
done

# ── Assertion 3: the grace period is ordered before the escalation ──
# Force-cancel bypasses always() conditions and cleanup steps, so it must never
# be the first thing tried on a runner that was merely slow to ack.
#
# Each of the three call sites is located INDEPENDENTLY and their line numbers
# compared. An earlier version of this check grepped all three alternatives at
# once and compared the first three hits, which can never fail: grep -n emits
# matches in file order, so "increasing" was true by construction. It passed a
# copy with force-cancel hoisted above the graceful cancel.
S="$(python3 -c 'import yaml,sys; sys.stdout.write(yaml.safe_load(open(sys.argv[1]))["jobs"]["unjam"]["steps"][0]["run"])' "$REPO_ROOT/.github/workflows/unjam-ship.yml")"
line_of() { echo "$S" | grep -n -- "$1" | head -1 | sed 's/:.*//'; }
L_CANCEL=$(line_of 'gh_api -X POST "$api/actions/runs/$id/cancel"')
L_SLEEP=$(line_of 'sleep "$GRACE_SECONDS"')
L_FORCE=$(line_of 'gh_api -X POST "$api/actions/runs/$id/force-cancel"')
ck "ordering: graceful cancel, then grace period, then force-cancel" \
   "$(if [ -n "$L_CANCEL" ] && [ -n "$L_SLEEP" ] && [ -n "$L_FORCE" ] \
        && [ "$L_CANCEL" -lt "$L_SLEEP" ] && [ "$L_SLEEP" -lt "$L_FORCE" ]; \
      then echo ordered; else echo "out-of-order(cancel=$L_CANCEL sleep=$L_SLEEP force=$L_FORCE)"; fi)" "ordered"

echo ""
echo "  passed $pass, failed $fail"
[ "$fail" -eq 0 ] || exit 1
