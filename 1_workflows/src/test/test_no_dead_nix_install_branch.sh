#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 38 tester — no dead `nix profile install` branch           ║
# ║                                                                  ║
# ║ Audit follow-up (2026-05-05): cloud-ship-lib.sh nix_install()    ║
# ║ had a `profile` case that called `nix profile install`. Zero     ║
# ║ consumers ever set DEPS_NIX_METHOD=profile (default is "shell"); ║
# ║ the branch was dead code AND violated the "no host-state         ║
# ║ mutation" rule that applies to every other path in the engine.   ║
# ║                                                                  ║
# ║ This test prevents the dead path from creeping back. If you      ║
# ║ truly need persistence, declare the dep in a flake.              ║
# ║                                                                  ║
# ║ Usage: bash 1_workflows/src/test/test_no_dead_nix_install_branch.sh
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LIB="$REPO_ROOT/1_workflows/src/scripts/cloud-ship-lib.sh"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── No 'nix profile install' invocations in engine scripts ──"

# Scope: every cloud-ship-*.sh and the lib. Excludes comment lines.
HITS=()
while IFS= read -r f; do
    rel="${f#$REPO_ROOT/}"
    while IFS= read -r line; do
        HITS+=("$rel:$line")
    done < <(grep -nE 'nix profile install' "$f" 2>/dev/null \
             | grep -vE '^[0-9]+:\s*#' \
             | grep -vE '^[0-9]+:\s*//' \
             || true)
done < <(find "$REPO_ROOT/1_workflows/src/scripts" -name 'cloud-ship-*.sh' -type f 2>/dev/null)

if [ "${#HITS[@]}" -eq 0 ]; then
    pass "no executable 'nix profile install' calls (host-state mutation forbidden)"
else
    fail "${#HITS[@]} 'nix profile install' invocation(s) — must be 'nix shell' / 'nix build':"
    for h in "${HITS[@]}"; do
        printf "    %s\n" "$h" >&2
    done
fi

# Also assert DEPS_NIX_METHOD case statement only has the shell path.
if [ -f "$LIB" ]; then
    if grep -qE 'DEPS_NIX_METHOD.*profile|profile\)\s*$' "$LIB"; then
        # Allow comment mentions of `profile`, but flag executable `case` patterns.
        if grep -nE '^\s*profile\)\s*$' "$LIB" | grep -q .; then
            fail "cloud-ship-lib.sh has live 'profile)' case branch — should be deleted"
            grep -nE '^\s*profile\)\s*$' "$LIB" | sed 's/^/    /' >&2
        fi
    else
        pass "cloud-ship-lib.sh has no live 'profile)' case branch"
    fi
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "Phase 38 no-dead-nix-install: PASS"
    exit 0
else
    echo "Phase 38 no-dead-nix-install: FAIL"
    exit 1
fi
