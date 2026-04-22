#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 4 tester — build-{container}.json pattern integrity        ║
# ║                                                                  ║
# ║ Proves:                                                          ║
# ║   Every service that declares a `src/build-<container>.json`     ║
# ║   symlink resolves to an existing file. Catches the half-done    ║
# ║   rename that broke the 2026-04-20 ship (pre-staged symlinks     ║
# ║   for build-caddy / build-redis pointing to non-existent data    ║
# ║   files).                                                         ║
# ║                                                                  ║
# ║ Declarative contract:                                            ║
# ║   a_solutions/<dir>/src/build-<container>.json  ──▶              ║
# ║   ../../../2_configs/dist/build-<container>.json (real file)       ║
# ║   OR  ../build-<container>.json (service-local real file)        ║
# ║                                                                  ║
# ║ Usage: bash 1_workflows/src/test/test_build_container_json_pattern.sh
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── Every src/build-<container>.json symlink must resolve ──"

checked=0
while IFS= read -r link; do
    [ -n "$link" ] || continue
    checked=$((checked + 1))
    target=$(readlink "$link")
    real_target=$(readlink -f "$link" 2>/dev/null || true)
    svc_rel=${link#"$REPO_ROOT/"}
    if [ -n "$real_target" ] && [ -e "$real_target" ]; then
        pass "$svc_rel → $target"
    else
        fail "$svc_rel → $target (DANGLING — target does not exist)"
    fi
done < <(find "$REPO_ROOT/a_solutions" \
    -maxdepth 3 -type l -name 'build-*.json' \
    -not -path "*/dist/*" \
    -not -path "*/z_archive/*" 2>/dev/null)

if [ "$checked" -eq 0 ]; then
    echo "  (no build-<container>.json symlinks found — pattern not yet adopted)"
fi

echo ""
echo "── preflight-symlinks invariant (defensive cross-check) ──"

broken=$(find "$REPO_ROOT/a_solutions" -xtype l \
    -not -path "*/.git/*" \
    -not -path "*/dist/*" \
    -not -path "*/target/*" \
    -not -path "*/node_modules/*" \
    -not -path "*/z_archive/*" 2>/dev/null || true)

if [ -z "$broken" ]; then
    pass "no broken symlinks anywhere under a_solutions/"
else
    fail "broken symlinks found:"
    echo "$broken" | sed 's/^/    /' >&2
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "══════════════════════════════════════════════"
    echo "Phase 4 build-{container}.json pattern: PASS"
    echo "══════════════════════════════════════════════"
    exit 0
else
    echo "══════════════════════════════════════════════"
    echo "Phase 4 build-{container}.json pattern: FAIL"
    echo "══════════════════════════════════════════════"
    exit 1
fi
