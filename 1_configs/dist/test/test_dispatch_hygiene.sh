#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/test/test_dispatch_hygiene.sh
# ║   Engine : 1_configs/src/gha/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 0 tester — dispatch + nix-step hygiene                     ║
# ║                                                                  ║
# ║ Proves:                                                          ║
# ║   H) dispatch sources cloud-ship-lib.sh so `log` exists          ║
# ║   I) only dispatch updates 1_configs/dist submodule; nix step      ║
# ║      honours CLOUD_DATA_PRESTAGED_BY_CI flag                     ║
# ║                                                                  ║
# ║ Usage: bash 1_configs/src/test/test_dispatch_hygiene.sh        ║
# ║        (also invoked from .github/workflows/ship-ci-image.yml)   ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

# Repo root by upward search, not a fixed ../../.. — this file exists at BOTH
# 1_configs/src/test/ and 1_configs/dist/test/ (generated), which sit at
# different depths, so one literal count is wrong for one of the two copies.
REPO_ROOT="$(_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
SCRIPTS="$REPO_ROOT/1_configs/src/gha/scripts"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── H: dispatch sources cloud-ship-lib.sh ──"

if grep -q '\. "\$_DISPATCH_DIR/cloud-ship-lib.sh"' "$SCRIPTS/cloud-ship-ci-builder-dispatch.sh"; then
    pass "dispatch.sh sources cloud-ship-lib.sh"
else
    fail "dispatch.sh missing 'source cloud-ship-lib.sh' — 'log: command not found' will recur"
fi

# Verify first `log` call comes AFTER the source line
_SRC_LINE=$(grep -n '\. "\$_DISPATCH_DIR/cloud-ship-lib.sh"' "$SCRIPTS/cloud-ship-ci-builder-dispatch.sh" | head -1 | cut -d: -f1)
_FIRST_LOG=$(grep -n '^[^#]*\blog\b' "$SCRIPTS/cloud-ship-ci-builder-dispatch.sh" | head -1 | cut -d: -f1)
if [ -n "$_SRC_LINE" ] && [ -n "$_FIRST_LOG" ] && [ "$_SRC_LINE" -lt "$_FIRST_LOG" ]; then
    pass "source line ($_SRC_LINE) precedes first log call ($_FIRST_LOG)"
else
    fail "source line ($_SRC_LINE) does NOT precede first log call ($_FIRST_LOG)"
fi

echo ""
echo "── I: submodule update is serialized + centralised ──"

if grep -q 'flock -w 60 9' "$SCRIPTS/cloud-ship-ci-builder-dispatch.sh"; then
    pass "dispatch.sh wraps submodule update in flock"
else
    fail "dispatch.sh missing flock — parallel jobs will race on .git/modules/cloud-data/config"
fi

if grep -q 'submodule update --remote --init --force 1_configs/dist' "$SCRIPTS/cloud-ship-ci-builder-dispatch.sh"; then
    pass "dispatch.sh runs the submodule update itself"
else
    fail "dispatch.sh does not run submodule update — workers will race"
fi

if grep -q 'CLOUD_DATA_PRESTAGED_BY_CI' "$SCRIPTS/cloud-ship-container-step-build-nix.sh"; then
    _CTX=$(grep -B0 -A2 'CLOUD_DATA_PRESTAGED_BY_CI' "$SCRIPTS/cloud-ship-container-step-build-nix.sh" | grep -c 'skipping\|skipping$' || true)
    if [ "$_CTX" -gt 0 ]; then
        pass "nix step skips submodule update when CI pre-staged"
    else
        fail "nix step references flag but does not skip submodule update"
    fi
else
    fail "nix step does not honour CLOUD_DATA_PRESTAGED_BY_CI — will re-race"
fi

echo ""
echo "── J: ship-hm routing actually fires (regression: bash \${var:?msg} parses } early) ──"
# Pre-2026-04-25 dispatch had `CMD="${1:?Usage: dispatch.sh {ship|ship-hm} <vm>}"`
# — the embedded `}` inside `{ship|ship-hm}` terminated the parameter expansion,
# so CMD was "ship-hm <vm>}" not "ship-hm" and the routing branch never matched.
# This test calls dispatch.sh ship-hm in dry-run mode and asserts CMD parses
# clean. We trace the script and grep for the assignment.
_TRACE=$(bash -x "$SCRIPTS/cloud-ship-ci-builder-dispatch.sh" ship-hm noop 2>&1 | head -10 || true)
if echo "$_TRACE" | grep -qE "^\+ CMD=ship-hm$"; then
    pass "CMD parses cleanly to 'ship-hm' (no trailing literal)"
else
    fail "CMD parsing regressed — trace shows: $(echo "$_TRACE" | grep -E '^\+ CMD=' | head -1)"
fi

echo ""
echo "── H+I: shellcheck dispatch + nix-step ──"
# Executable scripts (have shebang): default shell detection.
# Sourced step files (no shebang by design — invoked via `.`/source): force --shell=bash.
_shellcheck_file() {
    local file="$1" mode="$2"
    if [ "$mode" = "sourced" ]; then
        shellcheck -S error --shell=bash -x "$file"
    else
        shellcheck -S error -x "$file"
    fi
}

if command -v shellcheck >/dev/null 2>&1; then
    # Format: "path|mode" where mode is 'executable' or 'sourced'
    for entry in \
        "$SCRIPTS/cloud-ship-ci-builder-dispatch.sh|executable" \
        "$SCRIPTS/cloud-ship-container-step-build-nix.sh|sourced"; do
        file="${entry%|*}"; mode="${entry##*|}"
        if _shellcheck_file "$file" "$mode" >/dev/null 2>&1; then
            pass "shellcheck clean: $(basename "$file") [$mode]"
        else
            fail "shellcheck errors in $(basename "$file") [$mode]:"
            _shellcheck_file "$file" "$mode" >&2 || true
        fi
    done
else
    echo "  ⚠ shellcheck not installed — skipping static check (not a failure)"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "══════════════════════════════════════════════"
    echo "Phase 0 hygiene: PASS"
    echo "══════════════════════════════════════════════"
    exit 0
else
    echo "══════════════════════════════════════════════"
    echo "Phase 0 hygiene: FAIL"
    echo "══════════════════════════════════════════════"
    exit 1
fi
