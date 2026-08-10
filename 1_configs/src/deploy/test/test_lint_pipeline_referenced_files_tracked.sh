#!/usr/bin/env bash
# Test: every `bash 1_configs/src/deploy/test/<file>.sh` invocation in
# lint-pipeline.yml references a file that exists in the repo AND is
# git-tracked AND is executable.
#
# Why: today (2026-04-27) saw `lint-pipeline.yml` reference Phase 25, 29,
# 31 testers (test_engine_steps_tracked.sh, test_ssh_builder_pins_workspace.sh,
# test_no_stale_cloud_data_symlinks.sh) where the file was added by an
# agent but not always tracked or executable on first commit. This lint
# catches the gap before a CI run hits "No such file" mid-pipeline.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LINT="$REPO_ROOT/1_configs/src/deploy/gha/cicd/lint-pipeline.yml"

[ -f "$LINT" ] || { echo "::error::$LINT not found"; exit 1; }

FAIL=0
EXAMINED=0

# Extract every `bash 1_configs/src/deploy/test/<file>.sh` (and dist/test/<file>.sh).
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
done < <(grep -oE 'bash 1_configs/(src|dist)/test/[a-z_-]+\.sh' "$LINT" | awk '{print $2}' | sort -u)

if [ "$EXAMINED" -eq 0 ]; then
    echo "  (no tester references found in lint-pipeline.yml — nothing to check)"
fi

if [ "$FAIL" -eq 1 ]; then
    echo
    echo "::error::lint-pipeline references files that aren't tracked / don't exist / aren't executable"
    exit 1
fi

echo
echo "All lint-pipeline tester references resolve to tracked + runnable files."
