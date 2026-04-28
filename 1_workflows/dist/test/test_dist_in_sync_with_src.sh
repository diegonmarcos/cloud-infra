#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_workflows/src/test/test_dist_in_sync_with_src.sh
# ║   Engine : 1_workflows/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Test: 1_workflows/dist/ + .github/workflows/ are in sync with the
# corresponding src/cicd/ + src/scripts/ + src/test/.
#
# Why: today (2026-04-27) saw multiple agents push src changes without
# running 1_workflows/build.sh deploy. Result: .github/workflows/ on
# origin diverged from src/cicd/ by 2+ commits, and ship runs failed at
# the matrix-detect step (cloud-data-gha-config.json missing because
# the regen pre-step lived in src but never got deployed).
#
# Fix: this lint runs `1_workflows/build.sh build` then checks that
# dist/ + .github/workflows/ match what the engine emits. Any drift
# fails the lint with a clear message pointing at the build step.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

[ -f "$REPO_ROOT/1_workflows/build.sh" ] || { echo "::error::build.sh not found"; exit 1; }

# Snapshot dist + .github/workflows BEFORE build, then re-build, diff.
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

cp -r "$REPO_ROOT/1_workflows/dist" "$TMP/dist-before" 2>/dev/null || true
cp -r "$REPO_ROOT/.github/workflows" "$TMP/wf-before" 2>/dev/null || true

# Re-emit dist + .github/workflows from src/.
( cd "$REPO_ROOT" && bash 1_workflows/build.sh ) >/dev/null 2>&1 || {
    echo "::error::1_workflows/build.sh failed — fix the engine before lint"
    exit 1
}

DRIFT=0

if ! diff -rq "$TMP/dist-before" "$REPO_ROOT/1_workflows/dist" >/tmp/dist-drift 2>&1; then
    if [ -s /tmp/dist-drift ]; then
        echo "::error::1_workflows/dist/ is out of sync with 1_workflows/src/"
        echo "Drift:"
        head -20 /tmp/dist-drift | sed 's/^/  /'
        echo "Fix: run 'bash 1_workflows/build.sh' and commit the dist/ changes."
        DRIFT=1
    fi
fi

if ! diff -rq "$TMP/wf-before" "$REPO_ROOT/.github/workflows" >/tmp/wf-drift 2>&1; then
    if [ -s /tmp/wf-drift ]; then
        echo "::error::.github/workflows/ is out of sync with 1_workflows/src/cicd/"
        echo "Drift:"
        head -20 /tmp/wf-drift | sed 's/^/  /'
        echo "Fix: run 'bash 1_workflows/build.sh' and commit the .github/workflows/ changes."
        DRIFT=1
    fi
fi

[ "$DRIFT" -eq 1 ] && exit 1

echo "1_workflows/dist/ + .github/workflows/ are in sync with src/."
