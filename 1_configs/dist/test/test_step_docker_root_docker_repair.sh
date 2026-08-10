#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/test/test_step_docker_root_docker_repair.sh
# ║   Engine : 1_configs/src/gha/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# test_step_docker_root_docker_repair.sh — guard the engine repair guard
#
# Bug: oci-apps host had /root/.docker/config.json existing as a DIRECTORY
# (created by a stale `docker run -v ~/.docker/config.json:/...` when the
# host file was missing — docker auto-creates missing bind sources as
# directories). docker login does atomic temp+rename over config.json,
# fails with "rename: device or resource busy" because the target is a
# directory.
#
# Surfaced 2026-05-07 (ship run 25490646324: c3-services-mcp build to
# oci-apps).
#
# Fix landed in cloud-ship-container-step-build-docker.sh:
# before each remote-build `ssh ... docker login`, the engine probes
# /root/.docker/config.json on the runner host; if it's a directory,
# `rm -rf`s it.
#
# This test enforces the guard's presence — every step_docker remote-build
# path MUST nuke a directory at /root/.docker/config.json before logging
# in. Removing the guard regresses the bug.
#
# Run:  bash 1_configs/src/test/test_step_docker_root_docker_repair.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Repo root by upward search, not a fixed ../../.. — this file exists at BOTH
# 1_configs/src/test/ and 1_configs/dist/test/ (generated), which sit at
# different depths, so one literal count is wrong for one of the two copies.
REPO_ROOT="$(_d="$SCRIPT_DIR"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
ENGINE="$REPO_ROOT/1_configs/src/gha/scripts/cloud-ship-container-step-build-docker.sh"

PASS=0
FAIL=0
ok()   { printf "  \xe2\x9c\x93 %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  \xe2\x9c\x97 %s\n" "$1" >&2; FAIL=$((FAIL+1)); }

echo "=== test_step_docker_root_docker_repair ==="

# Test 1: engine source has the directory check
if grep -qE '\[ -d /root/\.docker/config\.json \]' "$ENGINE"; then
    ok  "engine guards against /root/.docker/config.json being a directory"
else
    fail "engine missing the [ -d /root/.docker/config.json ] guard — bug can recur"
fi

# Test 2: guard's repair action present
if grep -qE 'rm -rf /root/\.docker/config\.json' "$ENGINE"; then
    ok  "engine performs rm -rf when target is a directory"
else
    fail "engine missing the rm -rf cleanup — guard is no-op"
fi

# Test 3: guard placed BEFORE the SSH-side docker login on RUNNER_HOST
# (the line that fires `ssh ... docker login ghcr.io ...`).  Earlier
# in the file there's a different login that runs in the cloud-builder-x
# container itself (not on the runner host) — that one is unrelated.
guard_ln=$(grep -nE '\[ -d /root/\.docker/config\.json \]' "$ENGINE" | head -1 | cut -d: -f1)
ssh_login_ln=$(grep -nE 'ssh \$SSH_OPTS .* docker login ghcr\.io' "$ENGINE" | head -1 | cut -d: -f1)
if [ -n "$guard_ln" ] && [ -n "$ssh_login_ln" ] && [ "$guard_ln" -lt "$ssh_login_ln" ]; then
    ok  "guard at line $guard_ln precedes SSH-side docker login at line $ssh_login_ln"
else
    fail "guard ($guard_ln) does NOT precede SSH-side docker login ($ssh_login_ln) — repair runs too late"
fi

echo
printf "  pass: %d\n  fail: %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "  step_docker /root/.docker repair guard intact"
