#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/cgc-db-queue-no-eviction.test.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# #418 — cgc-db runs must never silently evict each other.
#
# The defect: `concurrency: {group: cgc-db, cancel-in-progress: false}` holds ONE
# running and ONE pending run; every newer entrant CANCELS the pending one before
# it starts a single job. Measured 2026-09-24 over the last 40 cgc-db runs: 20
# `cancelled`, including 6 of the 8 workflow_dispatch reindexes — zero jobs each.
# 35908826779 was cancelled one second after schedule 35977946827 was created.
#
# The fix has two halves, and both are EXECUTED here, never grepped for text:
#   1. `queue: max` on the workflow-level group — FIFO, nothing evicted.
#   2. the `coalesce` job, which keeps that FIFO bounded (a run is ~14h of jobs and
#      cron fires every 12h). Its jq filter AND its run: script are extracted from
#      the workflow and run against a stubbed `gh`: a superseded scheduled run
#      must cancel ITSELF and must never exit 0 — the guard for "a run that did
#      no work reads as green".
# Both the source and the deployed .github/ copy are checked: the deployed one is
# what GitHub actually runs.
set -eu
REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; \
       else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "::error::needs jq + python3"; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# Fixture: the runs listing the coalesce step queries. ME=100 is the run deciding.
runs() { printf '{"workflow_runs":[%s]}' "$1"; }
R() { printf '{"id":%s,"event":"%s","status":"%s"}' "$1" "$2" "$3"; }

for f in 1_cicd/src/cicd/cgc-db.yml .github/workflows/cgc-db.yml; do
  Y="$REPO_ROOT/$f"
  [ -f "$Y" ] || { echo "  FAIL $f missing"; fail=$((fail+1)); continue; }
  echo "── $f"
  # Pull every value this tester needs OUT of the workflow. Nothing restated here.
  python3 - "$Y" "$T" <<'PY'
import sys, yaml
y = yaml.safe_load(open(sys.argv[1])); t = sys.argv[2]
c = y.get("concurrency") or {}
j = y.get("jobs", {})
co = j.get("coalesce", {})
step = (co.get("steps") or [{}])[0]
w = lambda n, v: open(f"{t}/{n}", "w").write("" if v is None else str(v))
w("group", c.get("group")); w("queue", c.get("queue")); w("cip", c.get("cancel-in-progress"))
w("co_if", co.get("if")); w("filter", (step.get("env") or {}).get("SUPERSEDED_BY"))
w("run", step.get("run")); w("sem_needs", j.get("semantic", {}).get("needs"))
w("sem_if", j.get("semantic", {}).get("if")); w("gr_if", j.get("graphrag", {}).get("if"))
PY

  # ── 1. no eviction ──
  ck "$f: workflow-level group is cgc-db" "$(cat "$T/group")" "cgc-db"
  ck "$f: queue: max (default 'single' evicts the pending run)" "$(cat "$T/queue")" "max"
  ck "$f: cancel-in-progress false (true + queue:max is a validation error)" "$(cat "$T/cip")" "False"

  # ── 2. the coalesce filter, executed ──
  FILTER=$(cat "$T/filter")
  [ -n "$FILTER" ] || { echo "  FAIL $f: no SUPERSEDED_BY filter on the coalesce step"; fail=$((fail+1)); continue; }
  sup() { printf '%s' "$1" | ME=100 jq -r "$FILTER"; }
  ck "$f: newer QUEUED schedule supersedes"      "$(sup "$(runs "$(R 100 schedule in_progress),$(R 140 schedule queued)")")" "140"
  ck "$f: newest of several wins"                "$(sup "$(runs "$(R 120 schedule pending),$(R 140 schedule queued)")")" "140"
  ck "$f: a queued DISPATCH never supersedes"    "$(sup "$(runs "$(R 140 workflow_dispatch queued)")")" ""
  ck "$f: an OLDER queued schedule does not"     "$(sup "$(runs "$(R 90 schedule queued)")")" ""
  ck "$f: a newer COMPLETED schedule does not"   "$(sup "$(runs "$(R 140 schedule completed)")")" ""
  ck "$f: only this run -> proceed"              "$(sup "$(runs "$(R 100 schedule in_progress)")")" ""
  ck "$f: coalesce runs on schedule only"        "$(cat "$T/co_if")" "\${{ github.event_name == 'schedule' }}"

  # ── 3. the run: script, executed with a stubbed gh — the no-work-must-not-exit-0 guard ──
  mkdir -p "$T/bin"
  cat > "$T/bin/gh" <<'GH'
#!/bin/sh
case "$1 $2" in
  "api "*) shift 2; while [ $# -gt 0 ]; do [ "$1" = --jq ] && { jq -r "$2" "$FIXTURE"; exit; }; shift; done ;;
  "run cancel") echo "$3" >> "$CANCELS" ;;
esac
GH
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/sleep"; chmod +x "$T/bin/gh" "$T/bin/sleep"
  sed 's/\${{ github.repository }}/o\/r/g' "$T/run" > "$T/run.sh"
  go() { # go <fixture-json> -> "rc=<n> cancels=<ids>"
    printf '%s' "$1" > "$T/fx"; : > "$T/cancels"
    rc=0; PATH="$T/bin:$PATH" FIXTURE="$T/fx" CANCELS="$T/cancels" ME=100 SUPERSEDED_BY="$FILTER" \
      sh -e "$T/run.sh" >/dev/null 2>&1 || rc=$?
    echo "rc=$rc cancels=$(tr '\n' ' ' < "$T/cancels" | sed 's/ $//')"; }
  ck "$f: superseded -> cancels ITSELF and never exits 0" \
     "$(go "$(runs "$(R 100 schedule in_progress),$(R 140 schedule queued)")")" "rc=1 cancels=100"
  ck "$f: not superseded -> proceeds (rc 0, cancels nothing)" \
     "$(go "$(runs "$(R 100 schedule in_progress)")")" "rc=0 cancels="

  # ── 4. a cancelled run must not start the phases ──
  ck "$f: semantic needs coalesce" "$(cat "$T/sem_needs")" "coalesce"
  ck "$f: semantic gated on !cancelled()" "$(grep -c '!cancelled()' "$T/sem_if" || true)" "1"
  ck "$f: graphrag uses !cancelled(), not always() (always() runs in a cancelled run)" \
     "$(grep -c 'always()' "$T/gr_if" || true)/$(grep -c '!cancelled()' "$T/gr_if" || true)" "0/1"
done

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
