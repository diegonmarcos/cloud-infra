#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/test/test_precommit_blocks_forced_add.sh
# ║   Engine : 1_configs/src/gha/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ════════════════════════════════════════════════════════════════════
# test_precommit_blocks_forced_add.sh
#
# Asserts that the pre-commit hook blocks a commit when a gitignored
# file has been force-staged via `git add -f`. Defends against the
# pattern that leaked decrypted secrets in the past.
# ════════════════════════════════════════════════════════════════════
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/pre-commit"
[ -x "$HOOK" ] || { echo "FAIL: pre-commit hook missing or not executable: $HOOK" >&2; exit 1; }

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

cd "$TMPDIR"
git init -q
git config user.email "t@t" && git config user.name "t"
echo "hi" > README.md && git add README.md && git commit -qm "seed"

echo '*.secret' > .gitignore
git add .gitignore && git commit -qm "gitignore"

# Case 1: plain `git add` of a gitignored file → git refuses
echo "bad" > leak.secret
if git add leak.secret 2>/dev/null; then
    fail "plain 'git add' should refuse a gitignored file"
else
    pass "plain 'git add' correctly refused the gitignored file"
fi

# Case 2: `git add -f` force-stages → hook must block
git add -f leak.secret
if "$HOOK" 2>/tmp/h; then
    fail "hook did NOT block a force-staged gitignored file (leak path)"
    cat /tmp/h
else
    rc=$?
    if [ "$rc" -eq 1 ] && grep -q 'BLOCKED' /tmp/h; then
        pass "hook blocked the commit (exit 1, BLOCKED message present)"
    else
        fail "hook exited $rc but didn't produce BLOCKED message"
        cat /tmp/h
    fi
fi

# Case 3: normal tracked-file change must NOT be blocked
git reset HEAD leak.secret >/dev/null
rm leak.secret
echo "update" >> README.md && git add README.md
if "$HOOK" >/dev/null 2>&1; then
    pass "hook allowed a normal tracked-file change"
else
    fail "hook incorrectly blocked a plain tracked-file commit"
fi

printf '\n═══ %d pass / %d fail ═══\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
