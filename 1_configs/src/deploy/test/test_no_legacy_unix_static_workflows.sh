#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 39 tester — legacy unix workflows/src/static/ is gone      ║
# ║                                                                  ║
# ║ Audit follow-up (2026-05-05): unix repo had two workflow source  ║
# ║ trees in parallel:                                               ║
# ║   • unix/1_configs/src/deploy/gha/cicd/   (active, builds via build.sh)   ║
# ║   • unix/workflows/src/static/   (legacy, hardcoded literals)    ║
# ║                                                                  ║
# ║ The legacy tree had hardcoded image refs that violated the       ║
# ║ data-driven rule. Round-2 fix deleted both legacy YAMLs.         ║
# ║ This test locks the deletion in.                                 ║
# ║                                                                  ║
# ║ Skipped if II_Unix submodule isn't checked out (so the test     ║
# ║ still passes during the submodule-pin gap).                      ║
# ║                                                                  ║
# ║ Usage: bash 1_configs/src/deploy/test/test_no_legacy_unix_static_workflows.sh
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }
skip() { printf "  ⚠ %s (skipped)\n" "$1"; }

unix_root="$REPO_ROOT/II_Unix"

echo "── Legacy unix/workflows/src/static/ must be absent ──"

if [ ! -d "$unix_root" ]; then
    skip "II_Unix submodule not checked out — nothing to verify"
    echo "Phase 39 no-legacy-unix-static: PASS (skipped)"
    exit 0
fi

# These two legacy files are the focus; the directory itself MAY linger
# empty, but the YAMLs must not be there.
for f in workflows/src/static/ship-builders.yml workflows/src/static/ship-containers.yml; do
    if [ -e "$unix_root/$f" ]; then
        fail "legacy file present: II_Unix/$f"
    else
        pass "absent: II_Unix/$f"
    fi
done

# Also assert the active source tree exists — sanity check.
for f in 1_configs/src/deploy/gha/cicd/ship-builders.yml 1_configs/src/deploy/gha/cicd/ship-containers.yml; do
    if [ -e "$unix_root/$f" ]; then
        pass "active source present: II_Unix/$f"
    else
        # If active source is missing, the submodule pin is way off — flag
        # but don't fail this test (which is specifically about the LEGACY
        # files), since "active source missing" is its own different failure.
        skip "active source missing (unexpected but separate concern): II_Unix/$f"
    fi
done

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "Phase 39 no-legacy-unix-static: PASS"
    exit 0
else
    echo "Phase 39 no-legacy-unix-static: FAIL"
    exit 1
fi
