#!/usr/bin/env bash
# #352/#375: cloud-u-android's per-repo index slice must END before its step does, so
# the partial checkpoint is published and the next run resumes. Run 37146011415: the
# budget clock started after ~17 min of clone/restore, handed out a 300-min slice in a
# 315-min step, the STEP timeout fired first, nothing was published, was=none forever.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
UPD="$ROOT/1_cicd/src/ops/cloud-cgc-db-update.sh"
for f in "$ROOT/1_cicd/src/cicd/cgc-db-index.yml" "$ROOT/.github/workflows/cgc-db-index.yml"; do
  step=$(awk '/^  index:/{i=1} i&&/- name: "cgc-db incremental update/{s=1} s&&/^        timeout-minutes:/{print $2; exit}' "$f")
  budget=$(awk '/^  index:/{i=1} i&&/^          CGC_BUDGET_MIN:/{gsub(/"/,"",$2); print $2; exit}' "$f")
  [ -n "$step" ] && [ -n "$budget" ] || { echo "FAIL $f: step=$step budget=$budget (missing)"; exit 1; }
  [ $((budget + 70)) -le "$step" ] || { echo "FAIL $f: budget $budget + 70min restore+publish reserve > step $step"; exit 1; }
  echo "ok $f: budget $budget + 70 <= step $step"
done
# The script must honour the env budget, and its clock must start before any clone.
grep -q 'BUDGET_MIN="${CGC_BUDGET_MIN:-' "$UPD" || { echo "FAIL update.sh ignores CGC_BUDGET_MIN"; exit 1; }
st=$(grep -n '^START_TS=' "$UPD" | head -1 | cut -d: -f1)
cl=$(grep -n 'ensure_repos\b' "$UPD" | grep -v '^[0-9]*:#' | grep -v '()' | head -1 | cut -d: -f1)
[ -n "$st" ] || { echo "FAIL update.sh has no top-level START_TS"; exit 1; }
[ "$(grep -c '^START_TS=' "$UPD")" = 1 ] || { echo "FAIL START_TS assigned twice (the late one resets the clock)"; exit 1; }
[ -z "$cl" ] || [ "$st" -lt "$cl" ] || { echo "FAIL START_TS (line $st) set after repos are cloned (line $cl)"; exit 1; }
echo "ok update.sh: budget from env, clock starts at line $st"
echo PASS
