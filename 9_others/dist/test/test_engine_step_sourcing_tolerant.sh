#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_engine_step_sourcing_tolerant.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Test: cloud-ship-container-engine.sh sources step files defensively
# (tolerates missing files via `[ -f ... ] && .`) instead of unconditional
# `. <path>` which aborts the engine before any step runs.
#
# Failure mode 2026-04-27 (run 24994988037): cloud-builder image's stale
# /root/git/cloud lacked cloud-ship-container-step-verify-secret-consumption.sh
# because the entrypoint's repo sync silently failed. Engine source line
# aborted with "No such file or directory" before printing the service
# header — c3-services-mcp + mail-mcp ship attempts both failed at line 188
# before any step (build/docker/secrets/deploy/compose) executed.
#
# This tester locks in the defensive pattern so any future regression that
# reverts to unconditional sourcing is caught at lint time.
set -eu

# Repo root by upward search, not a fixed ../../.. — this file exists at BOTH
# 9_others/test/ and 1_cicd/dist/test/ (generated), which sit at
# different depths, so one literal count is wrong for one of the two copies.
REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
ENGINE="$REPO_ROOT/1_cicd/src/scripts/cloud-ship-container-engine.sh"

[ -f "$ENGINE" ] || { echo "::error::$ENGINE not found"; exit 1; }

FAIL=0

# 1) No unconditional `. "$STEPS_DIR/cloud-ship-container-step-*.sh"` lines.
#    All sources must be guarded by `[ -f ... ]`.
UNGUARDED=$(grep -nE '^\. "\$STEPS_DIR/cloud-ship-container-step-' "$ENGINE" || true)
if [ -n "$UNGUARDED" ]; then
    printf "  FAIL unguarded step source(s) — would abort engine on missing file:\n%s\n" "$UNGUARDED"
    FAIL=1
else
    printf "  OK  no unguarded . \"\$STEPS_DIR/...\" lines\n"
fi

# 2) Engine must contain the defensive pattern (file-existence check before source).
if grep -qE '\[ -f "\$STEPS_DIR/\$_step" \]' "$ENGINE"; then
    printf "  OK  engine guards step source with [ -f ... ]\n"
else
    printf "  FAIL engine does not guard step source with [ -f ... ]\n"
    FAIL=1
fi

# 3) Engine must log a warning when a step is missing (so silent skips are visible).
if grep -qE 'step file missing' "$ENGINE"; then
    printf "  OK  engine logs missing step (visible drift signal)\n"
else
    printf "  FAIL engine does not log when a step file is missing — drift will be silent\n"
    FAIL=1
fi

# 4) All known step files must be referenced by the engine (regression
#    catcher: a step added under src/scripts/ but forgotten in the engine
#    loader will never source).
declare -i refs=0 known=0
for step_file in "$REPO_ROOT/1_cicd/src/scripts/cloud-ship-container-step-"*.sh; do
    [ -f "$step_file" ] || continue
    known=$((known + 1))
    base=$(basename "$step_file")
    if grep -q -- "$base" "$ENGINE"; then
        refs=$((refs + 1))
    else
        printf "  FAIL step file %s exists but engine does not reference it\n" "$base"
        FAIL=1
    fi
done
printf "  OK  %d/%d step files referenced by engine\n" "$refs" "$known"

if [ "$FAIL" -eq 1 ]; then
    echo
    echo "::error::engine step sourcing regression"
    exit 1
fi

echo
echo "Engine sources step files defensively — missing files log a warning instead of aborting."
