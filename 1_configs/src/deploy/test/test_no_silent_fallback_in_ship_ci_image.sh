#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 35 tester — no legacy cloud-data-gha-config.json fallback  ║
# ║                                                                  ║
# ║ Audit P1 #3 (2026-05-05): ship-ci-image.yml had a 9-step silent  ║
# ║ cascade that ended in a legacy `cloud-data-gha-config.json`      ║
# ║ lookup. If the new build-gha.json was missing on a stale image   ║
# ║ but the old file existed, the workflow used wrong data silently. ║
# ║                                                                  ║
# ║ Fix landed: removed the legacy branch; consolidated derivation   ║
# ║ now emits ::warning:: when used. This test prevents regression.  ║
# ║                                                                  ║
# ║ Comments referencing the old name are fine (historical context); ║
# ║ executable refs (file path lookups) must be gone.                ║
# ║                                                                  ║
# ║ Usage: bash 1_configs/src/deploy/test/test_no_silent_fallback_in_ship_ci_image.sh
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── No executable refs to legacy cloud-data-gha-config.json ──"

# Check both ship.yml and ship-ci-image.yml — same fallback class.
for src in \
    "$REPO_ROOT/1_configs/src/deploy/gha/cicd/ship-ci-image.yml" \
    "$REPO_ROOT/1_configs/src/deploy/gha/cicd/ship.yml"; do
    [ -f "$src" ] || continue
    rel="${src#$REPO_ROOT/}"
    # Find references to the legacy filename, then strip out comment lines.
    # YAML comments are `#`. The match must be a file path lookup (quoted
    # path or `[ -f ...]` style), not just the name in prose.
    bad=$(grep -nE 'cloud-data-gha-config\.json' "$src" \
          | grep -vE '^[0-9]+:\s*#' \
          | grep -vE '^[0-9]+:\s*//' \
          | grep -E '"\S*cloud-data-gha-config\.json"|\bf "\S*cloud-data-gha-config\.json"' \
          || true)
    if [ -n "$bad" ]; then
        fail "executable refs to legacy file in $rel:"
        echo "$bad" | sed 's/^/    /' >&2
    else
        pass "no executable cloud-data-gha-config.json refs in $rel"
    fi
done

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "Phase 35 no-silent-fallback: PASS"
    exit 0
else
    echo "Phase 35 no-silent-fallback: FAIL"
    exit 1
fi
