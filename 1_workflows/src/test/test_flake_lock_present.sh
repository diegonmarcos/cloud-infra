#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 13 tester — every flake.nix MUST ship a flake.lock         ║
# ║                                                                  ║
# ║ Without flake.lock committed, `nix build` in CI tries to update  ║
# ║ inputs by hitting GitHub API anonymously → HTTP 401 (rate limit) ║
# ║ → ship fails with cryptic "Bad credentials" error.               ║
# ║                                                                  ║
# ║ Data-driven (FIRE RULE 3): no hardcoded service list.            ║
# ║                                                                  ║
# ║ Fix when this fails: cd to the offending dir and run             ║
# ║   nix flake lock                                                 ║
# ║                                                                  ║
# ║ Usage: bash 1_workflows/src/test/test_flake_lock_present.sh      ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── Every flake.nix MUST ship a sibling flake.lock ──"

CHECKED=0
while IFS= read -r flake; do
  dir=$(dirname "$flake")
  rel=${flake#"$REPO_ROOT/"}
  if [ -f "$dir/flake.lock" ]; then
    pass "$rel"
    CHECKED=$((CHECKED + 1))
  else
    fail "$rel — missing $dir/flake.lock (run: cd $dir && nix flake lock)"
  fi
done < <(find "$REPO_ROOT/a_solutions" -maxdepth 4 -name flake.nix \
    -not -path "*/z_archive/*" \
    -not -path "*/node_modules/*" \
    -not -path "*/.direnv/*" 2>/dev/null)

if [ "$FAIL" -eq 0 ]; then
  echo ""
  echo "Phase 13 flake.lock: PASS ($CHECKED flakes)"
  exit 0
else
  echo ""
  echo "Phase 13 flake.lock: FAIL — commit the missing flake.lock files"
  exit 1
fi
