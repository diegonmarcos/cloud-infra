#!/usr/bin/env bash
# Test: every `bash 9_others/test/<file>.sh` invocation in
# lint-pipeline.yml references a file that exists in the repo AND is
# git-tracked AND is executable.
#
# Why: today (2026-04-27) saw `lint-pipeline.yml` reference Phase 25, 29,
# 31 testers (test_engine_steps_tracked.sh, test_ssh_builder_pins_workspace.sh,
# test_no_stale_cloud_data_symlinks.sh) where the file was added by an
# agent but not always tracked or executable on first commit. This lint
# catches the gap before a CI run hits "No such file" mid-pipeline.
set -eu

# Repo root by upward search, not a fixed ../../.. — this file exists at BOTH
# 9_others/test/ and 1_cicd/dist/test/ (generated), which sit at
# different depths, so one literal count is wrong for one of the two copies.
REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
LINT="$REPO_ROOT/1_cicd/src/cicd/lint-pipeline.yml"

[ -f "$LINT" ] || { echo "::error::$LINT not found"; exit 1; }

FAIL=0
EXAMINED=0

# Extract every `bash 9_others/test/<file>.sh` (and dist/test/<file>.sh).
while IFS= read -r path; do
    [ -z "$path" ] && continue
    EXAMINED=$((EXAMINED + 1))
    full="$REPO_ROOT/$path"
    if [ ! -f "$full" ]; then
        printf "  FAIL %s — referenced in lint-pipeline but file missing\n" "$path"
        FAIL=1
        continue
    fi
    if ! git -C "$REPO_ROOT" ls-files --error-unmatch "$path" >/dev/null 2>&1; then
        printf "  FAIL %s — file exists but not git-tracked\n" "$path"
        FAIL=1
        continue
    fi
    if [ ! -x "$full" ] && ! head -1 "$full" 2>/dev/null | grep -q "^#!"; then
        printf "  FAIL %s — not executable AND no shebang\n" "$path"
        FAIL=1
        continue
    fi
    printf "  OK  %s\n" "$path"
# `9_others/test/`, with src/ and dist/ optional: the pipeline invokes the
# testers straight out of 9_others/test/, and the older `(src|dist)` group made
# that middle segment MANDATORY. The pattern matched nothing, EXAMINED stayed 0,
# and the test reported success while checking not one file. `[a-z_-]` also
# dropped every name carrying a digit (test_secrets_v2_layout_path.sh).
done < <(grep -oE 'bash 9_others/(src/|dist/)?test/[a-z0-9_-]+\.sh' "$LINT" | awk '{print $2}' | sort -u)

# Zero references is not "nothing to check" — lint-pipeline.yml runs dozens of
# these, so an empty set means the pattern above has stopped matching the
# pipeline, exactly as it had. Fail, rather than pass on an empty set.
if [ "$EXAMINED" -eq 0 ]; then
    echo "::error::no tester references found in lint-pipeline.yml — the extraction pattern no longer matches the pipeline, so this test verified nothing"
    exit 1
fi

if [ "$FAIL" -eq 1 ]; then
    echo
    echo "::error::lint-pipeline references files that aren't tracked / don't exist / aren't executable"
    exit 1
fi

echo
echo "All lint-pipeline tester references resolve to tracked + runnable files."
