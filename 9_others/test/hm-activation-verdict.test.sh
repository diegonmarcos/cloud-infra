#!/usr/bin/env bash
# #657: a home-manager ship's verdict is the activation's own exit code, and the
# wait for it ends at the JOB's deadline — not at a constant of the engine's.
#
# The engine polled a detached activation for a fixed 30 min inside a 45-min
# job. Activations on the 1 GB VMs take 36-64 min, so every ship to them was
# declared FAILED while its generation went live, and the timeout cleanup
# deleted the log of the activation that was still running.
#
# This runs the SHIPPED wait (_hm_detached_wait, sourced from the step file)
# against real detached processes on this box — ssh is stubbed to run the
# remote command locally — and parses the workflow that hands it its deadline.
#
#   A  an activation outlasting a short fixed cap still gets its verdict
#   B  a non-zero exit comes back as that exit code
#   C  a wrapper killed without an exit code fails at once, not at the deadline
#   D  at the deadline: non-zero, says STILL RUNNING, keeps the markers, and
#      the real exit code still lands
#   U  a VM that stops answering is reported as unreachable at the deadline,
#      not as a slow activation (a wedged hub looks like that)
#   E  both activation paths (docker, remote build) go through that wait
#   W  the workflow's deadline fits inside the step, the step inside the job,
#      and the slowest measured activation fits inside the deadline
#
# HM_STEP_FILE / HM_WORKFLOW_FILE point it at a planted copy (mutation runs).
set -u

REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
STEP="${HM_STEP_FILE:-$REPO_ROOT/1_cicd/src/scripts/cloud-ship-nix-homemanager-step-deploy-activate.sh}"
WF="${HM_WORKFLOW_FILE:-$REPO_ROOT/1_cicd/src/cicd/ship-home-manager.yml}"

# Slowest activation measured when #657 was fixed — gcp-proxy 2026-09-30,
# launch 12:29:36 -> rc marker 13:33:35 = 64 min — plus the ~6 min of build,
# push and preflight that run before it inside the same step. A deadline under
# this re-creates #657 on the next slow ship.
MEASURED_WORST_MIN=70

pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; \
       else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }

[ -f "$STEP" ] || { echo "::error::step file not found: $STEP"; exit 1; }
T="$(mktemp -d)"
trap 'pkill -f "$T/" 2>/dev/null; rm -rf "$T"' EXIT

# run_case <name> <activation body> <seconds to deadline> -> RC, SECS, OUT, M
# Each case is capped at 90s: a wait that ignores its deadline must read as a
# FAIL here, not hang the lint job until GitHub kills it.
run_case() {
    M="$T/hm-act-$1-$$"; printf '%s\n' "$2" > "$M.sh"
    local t0; t0=$(date +%s)
    OUT="$(timeout 90 bash -c '
        ssh() { case "${POLLS_UNREACHABLE:-}${*: -1}" in 1*__HMRC__*) return 255 ;; esac; bash -c "${*: -1}"; }
        log() { printf "[log] %s\n" "$1"; }
        . "$1"
        DEPLOY_HOST=local SSH_OPTS="" BUILD_LOG_FILE=/dev/null
        HM_POLL_SECS=1 HM_DEADLINE_EPOCH=$(( $(date +%s) + $3 ))
        rc=0; _hm_detached_wait "$2.sh" case || rc=$?
        printf "\n__RC__%s" "$rc"' _ "$STEP" "$M" "$3")"
    case "$OUT" in *__RC__*) RC="${OUT##*__RC__}" ;; *) RC="hung(>90s)" ;; esac
    SECS=$(( $(date +%s) - t0 ))
}
has() { case "$OUT" in *"$1"*) echo yes ;; *) echo no ;; esac; }

echo "── #657: HM ship verdict = activation exit code, wait bounded by the job ──"

run_case A 'sleep 4; echo slow-but-fine; exit 0' 30
ck "A: activation slower than a short cap reports its own exit 0" "$RC" "0"
ck "A: its log was streamed" "$(has slow-but-fine)" "yes"
ck "A: markers cleaned up once the verdict is in" \
   "$(ls "$M.rc" "$M.log" "$M.pid" 2>/dev/null | wc -l | tr -d ' ')" "0"

run_case B 'exit 7' 30
ck "B: a failing activation's exit code comes back unchanged" "$RC" "7"

run_case C 'kill -KILL $PPID; exit 0' 30
ck "C: a killed wrapper (no exit code) is a failure" "$RC" "1"
ck "C: ...reported as not running, not as a timeout" "$(has 'not running and left no exit code')" "yes"
ck "C: ...within seconds, not at the 30s deadline" "$([ "$SECS" -lt 10 ] && echo fast || echo "slow(${SECS}s)")" "fast"

run_case D 'sleep 6; exit 0' 3
ck "D: still running at the deadline is non-zero" "$RC" "1"
ck "D: ...and says STILL RUNNING" "$(has 'STILL RUNNING')" "yes"
ck "D: ...and leaves the log and pid markers in place" \
   "$(ls "$M.log" "$M.pid" 2>/dev/null | wc -l | tr -d ' ')" "2"
for _ in $(seq 1 15); do [ -s "$M.rc" ] && break; sleep 1; done
ck "D: the activation's real exit code still lands afterwards" "$(cat "$M.rc" 2>/dev/null)" "0"

export POLLS_UNREACHABLE=1; run_case U 'sleep 5; exit 0' 3; unset POLLS_UNREACHABLE
ck "U: an unreachable VM at the deadline is non-zero" "$RC" "1"
ck "U: ...and is reported as unreachable, not STILL RUNNING" \
   "$(has 'could not reach')$(has 'STILL RUNNING')" "yesno"

ck "E: docker and remote-build paths both wait through _hm_detached_wait" \
   "$(grep -c '_hm_detached_wait "\$_rsh"' "$STEP")" "2"

W="$(python3 - "$WF" "$MEASURED_WORST_MIN" <<'PY'
import re, sys, yaml
wf, worst = yaml.safe_load(open(sys.argv[1])), int(sys.argv[2])
job = wf["jobs"]["deploy"]
ship = [s for s in job["steps"] if s.get("name") == "Ship"][0]
m = re.search(r"HM_DEADLINE_EPOCH=\$\(\( \$\(date \+%s\) \+ (\d+) \)\)", ship["run"])
d = int(m.group(1)) if m else -1
print("forwarded" if re.search(r"-e HM_DEADLINE_EPOCH\b", ship["run"]) else "not-forwarded")
print("inside-step" if 0 < d <= ship.get("timeout-minutes", 0) * 60 - 60 else f"outside-step(d={d})")
print("inside-job" if ship.get("timeout-minutes", 10**6) < job.get("timeout-minutes", 0) else "outside-job")
print("covers-measured" if d >= worst * 60 else f"below-measured(d={d}s<{worst}min)")
PY
)"
set -- $W
ck "W: the deadline is forwarded into the builder container" "${1:-}" "forwarded"
ck "W: the deadline ends >=1 min before the Ship step's timeout" "${2:-}" "inside-step"
ck "W: the Ship step's timeout is inside the job's" "${3:-}" "inside-job"
ck "W: the deadline covers the slowest measured activation (${MEASURED_WORST_MIN}m)" "${4:-}" "covers-measured"

echo ""
echo "  passed $pass, failed $fail"
[ "$pass" -gt 0 ] && [ "$fail" -eq 0 ]
