#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/cgc-db-index-step-timeout.test.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

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
echo PASS
