#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/test/test_no_legacy_b_infra_home_manager.sh
# ║   Engine : 1_configs/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# test_no_legacy_b_infra_home_manager.sh — guard against the old layout
# resurfacing.
#
# Pre-2026-05-06 layout: b_infra/home-manager/<vm>/ + b_infra/home-manager/_shared/
# Post-restructure layout: b_infra/nixhm-sudo-<vm>/ + b_infra/_shared/
# (commit f45d45709 in cloud).
#
# This test fails if b_infra/home-manager/ ever reappears in git or on disk
# (a `git mv` to recreate it, or a manual mkdir). It also flags any source
# file (excluding submodules + dist + z_archive) that still references the
# legacy path — those will hit symlink-not-found at runtime.
#
# Run:  bash 1_configs/src/test/test_no_legacy_b_infra_home_manager.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

PASS=0
FAIL=0
ok()   { printf "  \xe2\x9c\x93 %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  \xe2\x9c\x97 %s\n" "$1" >&2; FAIL=$((FAIL+1)); }

echo "=== test_no_legacy_b_infra_home_manager ==="

# Test 1: directory must not exist on disk
if [ -e "$REPO_ROOT/b_infra/home-manager" ]; then
    fail "b_infra/home-manager/ exists — should have been removed by f45d45709"
else
    ok  "b_infra/home-manager/ absent on disk"
fi

# Test 2: nothing tracked under b_infra/home-manager/
TRACKED=$(git -C "$REPO_ROOT" ls-files b_infra/home-manager/ 2>/dev/null | head -3)
if [ -n "$TRACKED" ]; then
    fail "b_infra/home-manager/ still has tracked files: $TRACKED"
else
    ok  "b_infra/home-manager/ has zero tracked files"
fi

# Test 3: every per-VM dir uses the new nixhm-sudo-<vm> layout (≥1 must
# exist; the set is discovered from disk so decommissioning a VM doesn't
# require editing this test — the legacy-layout guard above is the actual
# regression check).
shopt -s nullglob
NIXHM_DIRS=("$REPO_ROOT"/b_infra/nixhm-sudo-*)
shopt -u nullglob
if [ ${#NIXHM_DIRS[@]} -eq 0 ]; then
    fail "no b_infra/nixhm-sudo-*/ dirs found — new layout missing"
else
    for d in "${NIXHM_DIRS[@]}"; do
        ok  "b_infra/$(basename "$d")/ exists"
    done
fi

# Test 4: cloud-side source files do not reference the legacy path.
# Excludes: submodules, dist/, z_archive/, *.build-log, .claude/settings.local.
STALE=$(git -C "$REPO_ROOT" grep -l 'b_infra/home-manager' \
        ":!I_cloud-data" ":!II_tools" ":!III_unix" \
        ":!*/dist/*" ":!*/z_archive/*" ":!**/.build-log" \
        ":!.claude/settings.local.json" 2>/dev/null || true)
if [ -n "$STALE" ]; then
    echo "  ✗ source files still reference b_infra/home-manager:" >&2
    echo "$STALE" | sed 's/^/      /' >&2
    FAIL=$((FAIL+1))
else
    ok  "no source file references b_infra/home-manager"
fi

echo
printf "  pass: %d\n  fail: %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "  legacy layout fully retired"
