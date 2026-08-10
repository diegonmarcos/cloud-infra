#!/usr/bin/env bash
# test_ship_terraform_fetch_depth.sh
#
# Regression guard for the "fatal: invalid refspec 'HEAD~1'" failure.
#
# Two independent bugs combined to break Ship → terraform:
#   1. actions/checkout was using fetch-depth: 2 (no full history).
#   2. dorny/paths-filter was passed `base: HEAD~1` — which makes dorny
#      run `git fetch origin HEAD~1`, and HEAD~1 is NOT a valid REMOTE
#      refspec, so the fetch fails regardless of local depth.
#
# This test enforces, in src/ + dist/ + .github/workflows/ copies:
#   - actions/checkout uses fetch-depth: 0
#   - no `base: HEAD~1` is passed to any action
set -euo pipefail

# Repo root by upward search, not a fixed ../../.. — this file exists at BOTH
# 1_configs/src/test/ and 1_configs/dist/test/ (generated), which sit at
# different depths, so one literal count is wrong for one of the two copies.
REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
FILES=(
  "$REPO_ROOT/1_configs/src/gha/cicd/ship-terraform.yml"
  "$REPO_ROOT/1_configs/dist/ship-terraform.yml"
  "$REPO_ROOT/.github/workflows/ship-terraform.yml"
)

fail=0
for f in "${FILES[@]}"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: missing $f"
    fail=1
    continue
  fi

  if ! grep -qE '^[[:space:]]+fetch-depth:[[:space:]]*0[[:space:]]*$' "$f"; then
    echo "FAIL: $f does not have 'fetch-depth: 0' (need full history for git diff HEAD^ HEAD)"
    fail=1
  fi

  if grep -qE '^[[:space:]]+base:[[:space:]]*HEAD~1[[:space:]]*$' "$f"; then
    echo "FAIL: $f passes 'base: HEAD~1' to an action — dorny/paths-filter will run 'git fetch origin HEAD~1' which is an invalid REMOTE refspec"
    fail=1
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "OK: ship-terraform fetch-depth and dorny base are correct in all 3 copies"
fi
exit "$fail"
