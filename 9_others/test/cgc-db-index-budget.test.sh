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
  # 30, was 70 (#888): the 57-min "restore" and "publish" of run 37929244331 were the
  # quadratic lance integrity scan; the real pull and publish of a 1G home take ~1m each.
  [ $((budget + 30)) -le "$step" ] || { echo "FAIL $f: budget $budget + 30min publish reserve > step $step"; exit 1; }
  echo "ok $f: budget $budget + 30 <= step $step"
  # The graphrag step (#888: same job as semantic under phase=both) starts at a varying
  # time, so its bound is a deadline from the job clock: deadline >= budget + 30 for
  # both modes, and below the job timeout so it ends as FAILURE, never CANCELLED.
  job=$(awk '/^  index:/{i=1} i&&/^    timeout-minutes:/{print $2; exit}' "$f")
  g=$(awk '/^  index:/{i=1} i&&/- name: "cgc-db graphrag update/{s=1} s' "$f")
  gb=$(printf '%s\n' "$g" | sed -n "s/^ *CGC_BUDGET_MIN: \${{ inputs.phase == 'both' \&\& '\([0-9]*\)' || '\([0-9]*\)' }}$/\1 \2/p")
  gd=$(printf '%s\n' "$g" | sed -n "s/^ *CGC_STEP_DEADLINE_MIN: \${{ inputs.phase == 'both' \&\& '\([0-9]*\)' || '\([0-9]*\)' }}$/\1 \2/p")
  read -r gb_both gb_one <<<"$gb"; read -r gd_both gd_one <<<"$gd"
  [ -n "${gb_both:-}" ] && [ -n "${gd_both:-}" ] || { echo "FAIL $f: graphrag step budget/deadline not found (budget=[$gb] deadline=[$gd])"; exit 1; }
  for m in both one; do
    eval "b=\$gb_$m d=\$gd_$m"
    [ $((b + 30)) -le "$d" ] || { echo "FAIL $f: graphrag ($m) budget $b + 30 > deadline $d"; exit 1; }
    [ "$d" -lt "$job" ] || { echo "FAIL $f: graphrag ($m) deadline $d >= job timeout $job"; exit 1; }
  done
  printf '%s\n' "$g" | grep -q 'CGC_START_TS + CGC_STEP_DEADLINE_MIN \* 60' && printf '%s\n' "$g" | grep -q 'timeout --kill-after=' \
    || { echo "FAIL $f: graphrag step does not enforce its deadline from the job clock"; exit 1; }
  awk '/^  index:/{i=1} i&&/- name: Job clock/{c=1} c&&/CGC_START_TS=/{print; exit}' "$f" | grep -q GITHUB_ENV \
    || { echo "FAIL $f: no job clock step exporting CGC_START_TS"; exit 1; }
  echo "ok $f: graphrag budget $gb_both/$gb_one, deadline $gd_both/$gd_one < job $job"
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
