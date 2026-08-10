#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/deploy/test/test_gitignore_synced.sh
# ║   Engine : 1_configs/src/deploy/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ╔══════════════════════════════════════════════════════════════════╗
# ║ Workflow engine tester — .gitignore src/dist/root parity         ║
# ║                                                                  ║
# ║ Proves:                                                          ║
# ║   The repo-root .gitignore is derived from                       ║
# ║   1_configs/src/gitignore via the workflow engine.             ║
# ║                                                                  ║
# ║ Invariants (post-header-injection):                              ║
# ║   1. src/gitignore exists (the source of truth)                  ║
# ║   2. dist/.gitignore exists and == root .gitignore (verbatim)    ║
# ║   3. dist/.gitignore carries the GENERATED-FILE banner           ║
# ║   4. dist/.gitignore, with its banner removed, == src/gitignore  ║
# ║                                                                  ║
# ║ Drift means someone hand-edited one of the three copies.         ║
# ║                                                                  ║
# ║ Usage: bash 1_configs/src/deploy/test/test_gitignore_synced.sh        ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

# Repo root by upward search, not a fixed ../../.. — this file exists at BOTH
# 1_configs/src/deploy/test/ and 1_configs/dist/test/ (generated), which sit at
# different depths, so one literal count is wrong for one of the two copies.
REPO_ROOT="$(_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"

SRC="$REPO_ROOT/1_configs/src/gitignore"
DIST="$REPO_ROOT/1_configs/dist/.gitignore"
ROOT="$REPO_ROOT/.gitignore"
HEADER_JSON="$REPO_ROOT/1_configs/src/engine/libs/generated-header.json"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

MARKER="$(jq -r '.marker' "$HEADER_JSON")"

echo "── .gitignore must be owned by 1_configs/src/ ──"
[ -f "$SRC" ]  && pass "source exists: 1_configs/src/gitignore"         || fail "missing source: 1_configs/src/gitignore"
[ -f "$DIST" ] && pass "dist artifact exists: 1_configs/dist/.gitignore" || fail "missing dist (run ./1_configs/build.sh build)"
[ -f "$ROOT" ] && pass "deployed copy exists: .gitignore"                  || fail "missing deploy (run ./1_configs/build.sh deploy)"

# 1. dist == root (deploy is a verbatim copy)
if [ -f "$DIST" ] && [ -f "$ROOT" ]; then
    if cmp -s "$DIST" "$ROOT"; then
        pass "dist/.gitignore == .gitignore (root)"
    else
        fail "dist/.gitignore diverges from root — rerun ./1_configs/build.sh"
    fi
fi

# 2. dist carries the banner
if [ -f "$DIST" ] && [ -n "$MARKER" ]; then
    if head -n 15 "$DIST" | grep -qF "$MARKER"; then
        pass "dist/.gitignore carries the GENERATED-FILE banner"
    else
        fail "dist/.gitignore missing GENERATED-FILE banner"
    fi
fi

# 3. dist minus banner == src (the original content is preserved verbatim
#    after the banner block + blank line). Strip everything up to and
#    including the closing banner line, plus the trailing blank.
if [ -f "$SRC" ] && [ -f "$DIST" ]; then
    tmp=$(mktemp)
    # Find the line number of the closing banner box (first line matching `╚`)
    close_line=$(grep -n '╚' "$DIST" | head -n1 | cut -d: -f1 || true)
    if [ -n "$close_line" ]; then
        # Skip banner + blank separator line
        tail -n +$((close_line + 2)) "$DIST" > "$tmp"
        if cmp -s "$SRC" "$tmp"; then
            pass "dist/.gitignore (banner-stripped) == src/gitignore"
        else
            fail "dist/.gitignore body diverges from src/gitignore — drift"
        fi
    else
        fail "dist/.gitignore banner malformed (no closing '╚' line)"
    fi
    rm -f "$tmp"
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
