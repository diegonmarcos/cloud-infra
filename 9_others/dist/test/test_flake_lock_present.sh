#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_flake_lock_present.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

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
# ║ Usage: bash 9_others/test/test_flake_lock_present.sh      ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

# Repo root by upward search, not a fixed ../../.. — this file exists at BOTH
# 9_others/test/ and 1_cicd/dist/test/ (generated), which sit at
# different depths, so one literal count is wrong for one of the two copies.
REPO_ROOT="$(_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── Every flake.nix MUST ship a sibling flake.lock ──"

CHECKED=0
cd "$REPO_ROOT"
# Filesystem `[ -f ]` checks pass on the dev disk even when flake.lock is
# untracked — but CI checks out only tracked files, so the same lock would
# be missing there. Use `git ls-files` so the local run matches CI's view
# and a developer catches the bug pre-push instead of in GHA.
while IFS= read -r flake; do
  dir=$(dirname "$flake")
  rel=${flake#"$REPO_ROOT/"}
  lock="$dir/flake.lock"
  rel_lock=${lock#"$REPO_ROOT/"}
  # 2026-09-06: `git -C "$dir"` — a_solutions is its own checkout now (not a
  # submodule), so a plain ls-files from REPO_ROOT sees NOTHING under it and
  # reported every lock as UNTRACKED. Asking the repo that owns the file works
  # for a nested checkout, a submodule and an in-tree directory alike.
  if git -C "$dir" ls-files --error-unmatch flake.lock >/dev/null 2>&1; then
    pass "$rel"
    CHECKED=$((CHECKED + 1))
  elif [ -f "$lock" ]; then
    fail "$rel — $rel_lock exists on disk but is UNTRACKED (run: git add $rel_lock)"
  else
    fail "$rel — missing $rel_lock (run: cd $dir && nix flake lock && git add flake.lock)"
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
