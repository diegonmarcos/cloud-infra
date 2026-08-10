#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/test/test_docker_npm_baked_into_image.sh
# ║   Engine : 1_configs/src/gha/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# test_docker_npm_baked_into_image.sh — guard data-driven npm bake
#
# Bug history (fixed 2026-05-07):
#   `cloud-ship-terraform-deploy-apply.sh:ensure_wrangler` did
#   `npm install -g wrangler` at deploy time, every CI invocation,
#   with stderr discarded and version unpinned. When npm hiccupped
#   (network, registry, perms), the function exited 1 with NO error
#   surface — the GHA log just said "Installing wrangler..." and then
#   "Process completed with exit code 1." 5 consecutive Ship → terraform
#   failures.
#
# Fix:
#   1. Move wrangler (+ any future npm globals) into config.json
#      .deps.docker_npm — single source of truth, version-pinned.
#   2. unix/cb_containers-builders/build.sh STEP 1 emits one
#      `npm install -g <pkg>@<ver>` per docker_npm entry into
#      docker-deps.sh, baked into the image at build time.
#   3. ensure_wrangler now FAILS LOUD if wrangler missing (image stale).
#
# This test enforces the contract: every binary listed in
# config.json:.deps.docker_npm has a corresponding `npm install -g`
# line in the rendered docker-deps.sh.
#
# Run:  bash 1_configs/src/test/test_docker_npm_baked_into_image.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Repo root by upward search, not a fixed ../../.. — this file exists at BOTH
# 1_configs/src/test/ and 1_configs/dist/test/ (generated), which sit at
# different depths, so one literal count is wrong for one of the two copies.
REPO_ROOT="$(_d="$SCRIPT_DIR"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
CONFIG="$REPO_ROOT/config.json"
# Resolve unix repo. Prefer the standalone clone at ~/git/unix (the
# editable SOURCE), fall back to the submodule pin in cloud (which can
# be stale until the pin is bumped post-commit).
if [ -d "${HOME}/git/unix/cb_containers-builders" ]; then
    UNIX_DIR="${HOME}/git/unix"
elif [ -d "$REPO_ROOT/II_Unix" ]; then
    UNIX_DIR="$REPO_ROOT/II_Unix"
else
    echo "  ✗ no unix repo found (checked ~/git/unix and II_Unix submodule)" >&2
    exit 1
fi
DEPS_SH="$UNIX_DIR/cb_containers-builders/dist/docker-deps.sh"

PASS=0
FAIL=0
ok()   { printf "  \xe2\x9c\x93 %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  \xe2\x9c\x97 %s\n" "$1" >&2; FAIL=$((FAIL+1)); }

echo "=== test_docker_npm_baked_into_image ==="

# Test 1: config.json has docker_npm slot
if jq -e '.deps.docker_npm' "$CONFIG" >/dev/null 2>&1; then
    ok  "config.json declares .deps.docker_npm"
else
    fail "config.json missing .deps.docker_npm — runtime npm-install will resurface"
    exit 1
fi

# Test 2: each non-doc entry has a pinned version (string, not null)
bad_pins=$(jq -r '.deps.docker_npm | to_entries | map(select(.key | startswith("_") | not) | select((.value | type) != "string" or (.value | length) == 0)) | .[].key' "$CONFIG" 2>/dev/null || true)
if [ -z "$bad_pins" ]; then
    ok  "all docker_npm entries are version-pinned strings"
else
    fail "unpinned docker_npm entries: $bad_pins"
fi

# Test 3: build.sh in cb_containers-builders emits npm install for each
# (best-effort path resolution — if unix/ is co-located).
if [ -f "$DEPS_SH" ]; then
    pkgs=$(jq -r '.deps.docker_npm | to_entries | map(select(.key | startswith("_") | not) | "\(.key)@\(.value)") | .[]' "$CONFIG" 2>/dev/null)
    while IFS= read -r pin; do
        [ -z "$pin" ] && continue
        if grep -qE "npm install -g $pin" "$DEPS_SH"; then
            ok  "docker-deps.sh has 'npm install -g $pin'"
        else
            fail "docker-deps.sh MISSING 'npm install -g $pin' — image won't bake it"
        fi
    done <<< "$pkgs"
else
    echo "  · skipping dist/docker-deps.sh check (run \`bash unix/cb_containers-builders/build.sh build\` first)"
fi

# Test 4: terraform engine no longer runtime-installs wrangler
ENGINE="$REPO_ROOT/1_configs/src/gha/scripts/cloud-ship-terraform-deploy-apply.sh"
if grep -qE '^[[:space:]]*npm install -g wrangler[[:space:]]*$' "$ENGINE"; then
    fail "terraform engine still runs 'npm install -g wrangler' — bake-into-image fix incomplete"
else
    ok  "terraform engine does NOT runtime-install wrangler"
fi

# Test 5: terraform engine ensure_wrangler fails loud if missing
if grep -qE 'FATAL.*wrangler.*not on PATH' "$ENGINE"; then
    ok  "ensure_wrangler fails loud on missing binary (no silent install)"
else
    fail "ensure_wrangler does not fail loud — silent npm fallback may have returned"
fi

echo
printf "  pass: %d\n  fail: %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "  data-driven npm bake contract intact"
