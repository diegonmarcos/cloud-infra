#!/usr/bin/env bash
# #352/#375: the per-repo index STEP must time out before its JOB does, so a slow
# repo ends the run as FAILURE (graphrag still runs) and not CANCELLED (graphrag skipped).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
for f in "$ROOT/1_cicd/src/cicd/cgc-db-index.yml" "$ROOT/.github/workflows/cgc-db-index.yml"; do
  job=$(awk '/^  index:/{i=1} i&&/^    timeout-minutes:/{print $2; exit}' "$f")
  step=$(awk '/^  index:/{i=1} i&&/- name: "cgc-db incremental update/{s=1} s&&/^        timeout-minutes:/{print $2; exit}' "$f")
  [ -n "$job" ] && [ -n "$step" ] || { echo "FAIL $f: job=$job step=$step (missing)"; exit 1; }
  [ "$step" -lt "$job" ] || { echo "FAIL $f: step $step >= job $job"; exit 1; }
  echo "ok $f: step $step < job $job"
done
grep -q "!cancelled()" "$ROOT/1_cicd/src/cicd/cgc-db.yml" && grep -q "needs.semantic.result == 'failure'" "$ROOT/1_cicd/src/cicd/cgc-db.yml" \
  || { echo "FAIL graphrag gate no longer accepts semantic failure"; exit 1; }
# 2026-10-05: a hosted-runner acquisition failure CANCELS a job (matrix leg or restore-all).
# graphrag must still run after a cancelled semantic result, and a restore-only retry must exist.
for f in "$ROOT/1_cicd/src/cicd/cgc-db.yml" "$ROOT/.github/workflows/cgc-db.yml"; do
  grep -q "needs.semantic.result == 'cancelled'" "$f" || { echo "FAIL $f: graphrag gate rejects cancelled semantic"; exit 1; }
  grep -q "^  restore-retry:" "$f" && grep -q "restore_only: true" "$f" || { echo "FAIL $f: restore-retry job missing"; exit 1; }
done
for f in "$ROOT/1_cicd/src/cicd/cgc-db-index.yml" "$ROOT/.github/workflows/cgc-db-index.yml"; do
  grep -q "restore_only:" "$f" && grep -q "if: \${{ !inputs.restore_only }}" "$f" || { echo "FAIL $f: restore_only input/gate missing"; exit 1; }
done
# #888: per-repo graphrag gating. Schedule and phase=both make ONE index call whose matrix
# job runs graphrag right after its own repo's semantic step; that step keeps the old
# gate's guarantee (runs after a failed semantic step) through !cancelled().
for f in "$ROOT/1_cicd/src/cicd/cgc-db.yml" "$ROOT/.github/workflows/cgc-db.yml"; do
  awk '/^  per-repo:/{p=1} p&&/^  [a-z]/&&!/^  per-repo:/{exit} p' "$f" | grep -q '^      phase: both$' \
    || { echo "FAIL $f: schedule/both no longer runs the per-repo semantic→graphrag call"; exit 1; }
  grep -q "needs.per-repo.result == 'cancelled'" "$f" || { echo "FAIL $f: restore-retry ignores a cancelled per-repo call"; exit 1; }
done
for f in "$ROOT/1_cicd/src/cicd/cgc-db-index.yml" "$ROOT/.github/workflows/cgc-db-index.yml"; do
  awk '/^  index:/{i=1} i&&/- name: "cgc-db graphrag update/{s=1} s&&/^        if:/{print; exit}' "$f" | grep -q "!cancelled() && (inputs.phase == 'graphrag' || inputs.phase == 'both')" \
    || { echo "FAIL $f: the graphrag step is not gated on !cancelled() (a failed semantic step would skip it)"; exit 1; }
  sem=$(awk '/^  index:/{i=1} i&&/- name: "cgc-db incremental update/{s=1} s&&/^      - name:/&&!/incremental update/{exit} s' "$f")
  gr=$(awk '/^  index:/{i=1} i&&/- name: "cgc-db graphrag update/{s=1} s' "$f")
  printf '%s\n' "$sem" | grep -q 'CGC_MANIFEST_PHASE: semantic' && printf '%s\n' "$sem" | grep -q 'USE_LLM: "false"' \
    || { echo "FAIL $f: semantic step is not pinned to the semantic phase"; exit 1; }
  printf '%s\n' "$gr" | grep -q 'CGC_MANIFEST_PHASE: graphrag' && printf '%s\n' "$gr" | grep -q 'USE_LLM: "true"' \
    || { echo "FAIL $f: graphrag step is not pinned to the graphrag phase"; exit 1; }
  gstep=$(printf '%s\n' "$gr" | awk '/^        timeout-minutes:/{print $2; exit}')
  job=$(awk '/^  index:/{i=1} i&&/^    timeout-minutes:/{print $2; exit}' "$f")
  [ -n "$gstep" ] && [ "$gstep" -lt "$job" ] || { echo "FAIL $f: graphrag step timeout ${gstep:-missing} not below job $job"; exit 1; }
done
echo PASS
