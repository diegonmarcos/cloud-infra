#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/test/test_step_docker_isolated_config.sh
# ║   Engine : 1_configs/src/gha/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# test_step_docker_isolated_config.sh — per-job DOCKER_CONFIG isolation
#
# Bug: GHA matrix Ship → gcp-proxy failed on http-to-smtp-proxy-api with
#   Error saving credentials: rename /root/.docker/config.json...:
#       device or resource busy
# Multiple matrix jobs share HOME=/root inside the cloud-builder image and
# raced on `docker login`'s atomic temp+rename over config.json. The losing
# job's `docker login` aborted before any build/push could happen, so the
# service was never shipped. Surfaced 2026-05-08.
#
# Fix landed in cloud-ship-container-step-build-docker.sh:
#   DOCKER_CONFIG=/tmp/docker-config-${SERVICE_NAME}-$$
#   mkdir -p "$DOCKER_CONFIG"
#   export DOCKER_CONFIG
# plus cleanup via the existing _docker_return_cleanup RETURN trap.
#
# This test enforces that the engine sets a per-job DOCKER_CONFIG before
# any docker login can run, the path includes BOTH $SERVICE_NAME and $$ for
# cross-service / cross-process uniqueness, and the path is cleaned up on
# function exit.
#
# Run:  bash 1_configs/src/test/test_step_docker_isolated_config.sh
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

echo "=== test_step_docker_isolated_config ==="

# Test 1: engine assigns DOCKER_CONFIG to a per-job /tmp path.
# Match the literal assignment so a future `export DOCKER_CONFIG=` (no path)
# or a hardcoded `/root/.docker` doesn't slip past.
docker_cfg_ln=$(grep -nE '^[[:space:]]*DOCKER_CONFIG="?/tmp/docker-config-' "$ENGINE" | head -1 | cut -d: -f1)
if [ -n "$docker_cfg_ln" ]; then
    ok  "engine sets DOCKER_CONFIG to a /tmp path (line $docker_cfg_ln)"
else
    fail "engine missing DOCKER_CONFIG=/tmp/docker-config-... assignment — rename race recurs"
fi

# Test 2: path includes $SERVICE_NAME (cross-service uniqueness)
if grep -qE 'DOCKER_CONFIG="?/tmp/docker-config-[^"]*\$\{?SERVICE_NAME' "$ENGINE"; then
    ok  "DOCKER_CONFIG path includes \$SERVICE_NAME (cross-service uniqueness)"
else
    fail "DOCKER_CONFIG path missing \$SERVICE_NAME — matrix jobs on same service-name reuse"
fi

# Test 3: path includes $$ (per-process uniqueness)
if grep -qE 'DOCKER_CONFIG="?/tmp/docker-config-[^"]*\$\$' "$ENGINE"; then
    ok  "DOCKER_CONFIG path includes \$\$ (per-PID uniqueness)"
else
    fail "DOCKER_CONFIG path missing \$\$ — concurrent same-name processes collide"
fi

# Test 4: engine creates the directory before exporting it
mkdir_ln=$(grep -nE '^[[:space:]]*mkdir -p "\$DOCKER_CONFIG"' "$ENGINE" | head -1 | cut -d: -f1)
export_ln=$(grep -nE '^[[:space:]]*export DOCKER_CONFIG[[:space:]]*$' "$ENGINE" | head -1 | cut -d: -f1)
if [ -n "$mkdir_ln" ] && [ -n "$export_ln" ]; then
    ok  "engine mkdir's (line $mkdir_ln) and exports (line $export_ln) DOCKER_CONFIG"
else
    fail "engine missing mkdir -p \"\$DOCKER_CONFIG\" or export DOCKER_CONFIG"
fi

# Test 5: DOCKER_CONFIG block fires BEFORE the first docker login call.
# Otherwise the login would still hit the shared /root/.docker/config.json.
first_login_ln=$(grep -nE 'docker login ghcr\.io' "$ENGINE" | head -1 | cut -d: -f1)
if [ -n "$docker_cfg_ln" ] && [ -n "$first_login_ln" ] && [ "$docker_cfg_ln" -lt "$first_login_ln" ]; then
    ok  "DOCKER_CONFIG set (line $docker_cfg_ln) before first docker login (line $first_login_ln)"
else
    fail "DOCKER_CONFIG set AFTER first docker login (cfg=$docker_cfg_ln login=$first_login_ln) — race not fixed"
fi

# Test 6: cleanup hooks into _docker_return_cleanup so every exit path frees
# the per-job dir. Catches a future refactor that drops the rm -rf inside
# the RETURN trap (would leak /tmp dirs across thousands of matrix jobs).
# Body extraction: enter on the function header line, exit on the first
# top-level `^}` (column-1 close brace, the canonical bash function close).
if awk '
    /^[[:space:]]*_docker_return_cleanup\(\)[[:space:]]*\{/ { in_fn=1; next }
    in_fn && /^\}/                                          { in_fn=0 }
    in_fn && /_DOCKER_CONFIG_OWNED/ && /rm -rf/             { found=1 }
    END { exit (found?0:1) }
' "$ENGINE"; then
    ok  "_docker_return_cleanup rm -rf's the per-job DOCKER_CONFIG dir"
else
    fail "_docker_return_cleanup missing rm -rf for per-job DOCKER_CONFIG — /tmp leaks"
fi

echo
printf "  pass: %d\n  fail: %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "  step_docker per-job DOCKER_CONFIG isolation intact"
