#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/test/test_engine_workspace_paths_derived.sh
# ║   Engine : 1_configs/src/gha/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 36 tester — engine scripts derive workspace paths          ║
# ║                                                                  ║
# ║ Audit P1 #4 (2026-05-05): cloud-ship-nix-homemanager-engine.sh   ║
# ║ hardcoded `/root/git/cloud/...` and `/root/git/cloud-data/...`,  ║
# ║ which breaks if the mount path differs (e.g. /workspace, local    ║
# ║ dev runs). Engine scripts MUST derive paths from $WORKSPACE or    ║
# ║ a default, not literal /root/git/.                               ║
# ║                                                                  ║
# ║ Allowed:                                                         ║
# ║   - "${WORKSPACE:-/root/git}/..." (env var with default)         ║
# ║   - "${VAR:-/root/git}/..." (any env-var defaulting form)        ║
# ║   - Comment lines                                                ║
# ║   - Inline doc strings (e.g. "// :ro at /root/.docker/...")       ║
# ║                                                                  ║
# ║ Forbidden:                                                       ║
# ║   - Bare `/root/git/cloud/...` or `/root/git/cloud-data/...`     ║
# ║                                                                  ║
# ║ Usage: bash 1_configs/src/test/test_engine_workspace_paths_derived.sh
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

# Repo root by upward search, not a fixed ../../.. — this file exists at BOTH
# 1_configs/src/test/ and 1_configs/dist/test/ (generated), which sit at
# different depths, so one literal count is wrong for one of the two copies.
REPO_ROOT="$(_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── Engine scripts must derive /root/git mount paths ──"

# Pattern: bare `/root/git/...` not preceded by `:-` (default-value form
# inside ${VAR:-/root/git/...}). Scope: cloud-ship-*.sh in scripts/ dir.
# Comment-only lines are skipped.
HITS=()
while IFS= read -r f; do
    rel="${f#$REPO_ROOT/}"
    # Find offending lines: contains /root/git/ AND the char before /root is
    # NOT `-` (which would mean ${VAR:-/root/git/...}). Skip comments.
    while IFS= read -r line; do
        # Skip default-value form: -/root/git
        echo "$line" | grep -qE '\-/root/git' && continue
        HITS+=("$rel:$line")
    done < <(grep -nE '/root/git/(cloud|cloud-data|unix)' "$f" 2>/dev/null \
             | grep -vE '^[0-9]+:\s*#' \
             | grep -vE '^[0-9]+:\s*//' \
             || true)
done < <(find "$REPO_ROOT/1_configs/src/gha/scripts" -name 'cloud-ship-*.sh' -type f 2>/dev/null)

if [ "${#HITS[@]}" -eq 0 ]; then
    pass "all engine scripts derive workspace paths from \$WORKSPACE / env defaults"
else
    fail "${#HITS[@]} bare /root/git literal(s) found — must be \${WORKSPACE:-/root/git}/...:"
    for h in "${HITS[@]}"; do
        printf "    %s\n" "$h" >&2
    done
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "Phase 36 workspace-paths: PASS"
    exit 0
else
    echo "Phase 36 workspace-paths: FAIL"
    exit 1
fi
