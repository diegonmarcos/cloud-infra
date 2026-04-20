#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 3E tester — npm ci services must have package-lock.json    ║
# ║                                                                  ║
# ║ Proves:                                                          ║
# ║   Every service whose docker.native_build.cmd starts with        ║
# ║   'npm ci' ships a package-lock.json in src/. Without it the     ║
# ║   CI container fails with EUSAGE.                                ║
# ║                                                                  ║
# ║ Usage: bash 1_workflows/src/test/test_npm_lockfile_present.sh    ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── Services using 'npm ci' must commit package-lock.json ──"

# Iterate every build.json — purely data-driven, no hardcoded service names
any_checked=0
for bj in "$REPO_ROOT"/a_solutions/*/build.json; do
    [ -f "$bj" ] || continue
    cmd=$(jq -r '.docker.native_build.cmd // empty' "$bj" 2>/dev/null)
    case "$cmd" in
        "npm ci"*)
            any_checked=1
            svc_dir=$(dirname "$bj")
            svc_name=$(basename "$svc_dir")
            lockfile="$svc_dir/src/package-lock.json"
            if [ -f "$lockfile" ]; then
                pass "$svc_name has package-lock.json"
            else
                fail "$svc_name declares 'npm ci' but lacks src/package-lock.json"
            fi
            ;;
    esac
done

if [ "$any_checked" -eq 0 ]; then
    echo "  (no service uses 'npm ci' — nothing to check)"
fi

echo ""
echo "── a_solutions/.gitignore must NOT ignore package-lock.json ──"

gi="$REPO_ROOT/a_solutions/.gitignore"
if [ -f "$gi" ] && grep -qE '^package-lock\.json$' "$gi"; then
    fail "a_solutions/.gitignore ignores package-lock.json — lockfiles will never be committed"
else
    pass "a_solutions/.gitignore does not ignore package-lock.json"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "══════════════════════════════════════════════"
    echo "Phase 3E npm lockfile: PASS"
    echo "══════════════════════════════════════════════"
    exit 0
else
    echo "══════════════════════════════════════════════"
    echo "Phase 3E npm lockfile: FAIL"
    echo "══════════════════════════════════════════════"
    exit 1
fi
