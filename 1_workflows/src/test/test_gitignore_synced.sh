#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Workflow engine tester — .gitignore source/dist/root parity      ║
# ║                                                                  ║
# ║ Proves:                                                          ║
# ║   The repo-root .gitignore is derived from                       ║
# ║   1_workflows/src/gitignore via the workflow engine. Source,     ║
# ║   dist artifact and deployed copy must be byte-identical.        ║
# ║                                                                  ║
# ║ Drift means someone hand-edited .gitignore at the root instead   ║
# ║ of editing 1_workflows/src/gitignore + running build.sh.         ║
# ║                                                                  ║
# ║ Usage: bash 1_workflows/src/test/test_gitignore_synced.sh        ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

SRC="$REPO_ROOT/1_workflows/src/gitignore"
DIST="$REPO_ROOT/1_workflows/dist/.gitignore"
ROOT="$REPO_ROOT/.gitignore"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── .gitignore must be owned by 1_workflows/src/ ──"

[ -f "$SRC" ]  && pass "source exists: 1_workflows/src/gitignore"     || fail "missing source: 1_workflows/src/gitignore"
[ -f "$DIST" ] && pass "dist artifact exists: 1_workflows/dist/.gitignore" || fail "missing dist: 1_workflows/dist/.gitignore (run ./1_workflows/build.sh build)"
[ -f "$ROOT" ] && pass "deployed copy exists: .gitignore"              || fail "missing deploy: .gitignore (run ./1_workflows/build.sh deploy)"

if [ -f "$SRC" ] && [ -f "$DIST" ]; then
    if cmp -s "$SRC" "$DIST"; then
        pass "dist/.gitignore == src/gitignore"
    else
        fail "dist/.gitignore diverges from src/gitignore — rerun ./1_workflows/build.sh build"
    fi
fi

if [ -f "$SRC" ] && [ -f "$ROOT" ]; then
    if cmp -s "$SRC" "$ROOT"; then
        pass ".gitignore (root) == src/gitignore"
    else
        fail ".gitignore (root) diverges from src/gitignore — someone hand-edited, rerun ./1_workflows/build.sh"
    fi
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "══════════════════════════════════════════════"
    echo "gitignore parity: PASS"
    echo "══════════════════════════════════════════════"
    exit 0
else
    echo "══════════════════════════════════════════════"
    echo "gitignore parity: FAIL"
    echo "══════════════════════════════════════════════"
    exit 1
fi
