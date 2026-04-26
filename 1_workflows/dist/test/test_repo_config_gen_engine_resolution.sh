#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_workflows/src/test/test_repo_config_gen_engine_resolution.sh
# ║   Engine : 1_workflows/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# test_repo_config_gen_engine_resolution.sh — verify
# cloud-ship-repo-config-gen.sh can find the cloud-data engine from a
# fresh checkout layout.
#
# Regression: the script searched for the engine at
#   <p>/1_workflows/src/scripts/cloud-data-config.ts
# inside three legacy roots (2_configs/dist, sibling cloud-data,
# /root/git/cloud-data). Post the 2026-04 engine reorg, the .ts files
# moved to cloud/2_configs/src/engines/ and the canonical entry point
# became cloud/2_configs/build.sh. Every gen-configs CI run logged
# "SKIP: cloud-data engine not found" and exited 1 — failure surfaced
# at run 24964978001 right after the cloud-builder entrypoint started
# completing past the GHCR step.
#
# This tester enforces:
#   1. The script tries cloud/2_configs/build.sh FIRST (current layout).
#   2. The legacy fallback path is still present (back-compat).
#   3. From a real cloud/ checkout, at least one resolution branch
#      exists and exits 0 in dry-mode (we don't actually run tsx; just
#      grep for the path the script would use).

set -euo pipefail

REPO="${GIT_BASE:-$HOME/git}/cloud"
SCRIPT="$REPO/1_workflows/src/scripts/cloud-ship-repo-config-gen.sh"
FAILS=0

[ -f "$SCRIPT" ] || { echo "✗ $SCRIPT not found"; exit 1; }

# 1. Current layout — 2_configs/build.sh dispatch is present and FIRST.
if grep -q '2_configs/build.sh.*all\|"$CLOUD_ROOT/2_configs/build.sh"' "$SCRIPT"; then
    echo "✓ script dispatches to 2_configs/build.sh (current engine layout)"
else
    echo "✗ script does not dispatch to 2_configs/build.sh — engine reorg not handled"
    FAILS=$((FAILS + 1))
fi

# Path A must come before Path B in the script (current preferred over legacy).
path_a_line=$(grep -n '2_configs/build.sh' "$SCRIPT" | head -1 | cut -d: -f1)
path_b_line=$(grep -n 'cloud-data-config\.ts' "$SCRIPT" | head -1 | cut -d: -f1)
if [ -n "$path_a_line" ] && [ -n "$path_b_line" ] && [ "$path_a_line" -lt "$path_b_line" ]; then
    echo "✓ Path A (current) precedes Path B (legacy)"
else
    echo "✗ Path A does not precede Path B — current layout not preferred (a:$path_a_line b:$path_b_line)"
    FAILS=$((FAILS + 1))
fi

# 2. Legacy fallback retained
if grep -q 'cloud-data-config\.ts' "$SCRIPT"; then
    echo "✓ legacy fallback (1_workflows/src/scripts/cloud-data-config.ts) still present"
else
    echo "✗ legacy fallback removed — back-compat broken"
    FAILS=$((FAILS + 1))
fi

# 3. Resolves on the actual checkout: 2_configs/build.sh exists and is executable
if [ -x "$REPO/2_configs/build.sh" ]; then
    echo "✓ 2_configs/build.sh is executable on this checkout"
else
    echo "✗ 2_configs/build.sh missing or non-executable — engine reorg incomplete"
    FAILS=$((FAILS + 1))
fi

# 4. The engine .ts file the legacy fallback expected lives at the new path
if [ -f "$REPO/2_configs/src/engines/cloud-data-config.ts" ]; then
    echo "✓ cloud-data-config.ts at new location: 2_configs/src/engines/"
else
    echo "✗ 2_configs/src/engines/cloud-data-config.ts missing"
    FAILS=$((FAILS + 1))
fi

# 5. Diagnostic on failure: error message lists what was tried.
if grep -q 'SKIP: neither 2_configs/build.sh nor cloud-data legacy engine found' "$SCRIPT"; then
    echo "✓ failure message names both paths attempted"
else
    echo "✗ failure message missing — debugger gets no breadcrumb"
    FAILS=$((FAILS + 1))
fi

if [ "$FAILS" -eq 0 ]; then
    echo "test_repo_config_gen_engine_resolution: PASS"
    exit 0
else
    echo "test_repo_config_gen_engine_resolution: FAIL ($FAILS check(s))"
    exit 1
fi
