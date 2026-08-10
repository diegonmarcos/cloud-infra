#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 9 tester — c3-services-mcp retry loop is bounded           ║
# ║                                                                  ║
# ║ Proves:                                                          ║
# ║   proxy-mcp.ts uses per-child exponential backoff + cleans up    ║
# ║   transport + client on connect failure. Absent these two, the   ║
# ║   fixed 30s interval + uncleaned transports grew the Node heap   ║
# ║   past the container's 512 MiB cgroup and OOM-killed the service ║
# ║   every ~75 min (H1 in the 2026-04-21 triage).                   ║
# ║                                                                  ║
# ║   Also asserts build.json declares resources.mem_limit and       ║
# ║   restart_policy — otherwise a crash leaves the container dead.  ║
# ║                                                                  ║
# ║ Usage: bash 1_configs/src/deploy/test/test_retry_bounded_backoff.sh   ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

# Repo root by upward search, not a fixed ../../.. — this file exists at BOTH
# 1_configs/src/deploy/test/ and 1_configs/dist/test/ (generated), which sit at
# different depths, so one literal count is wrong for one of the two copies.
REPO_ROOT="$(_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
SVC_DIR="$REPO_ROOT/a_solutions/infra-api_c3-services-mcp"
# v2 engine cutover (2026-04-22) moved code under src/code/. Keep backward-
# compatible resolution so the tester still works if either layout is used.
PROXY_TS=""
for _p in \
    "$SVC_DIR/src/code/mcp/tools/proxy-mcp.ts" \
    "$SVC_DIR/src/mcp/tools/proxy-mcp.ts"; do
    [ -f "$_p" ] && { PROXY_TS="$_p"; break; }
done
[ -z "$PROXY_TS" ] && { echo "  ✗ proxy-mcp.ts not found under src/code/ or src/" >&2; exit 1; }
BUILD_JSON="$SVC_DIR/build.json"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── 1: exponential backoff driven by build.json (data-driven) ──"

# New shape (2026-04-22 refactor): retry config lives in build.json, not as
# in-file constants. Assert the config exists + proxy-mcp.ts reads it +
# applies both doubling AND the bounded-LRU cap.
init_ms=$(jq -r '.proxied_mcps.retry.initial_ms // empty' "$BUILD_JSON")
max_ms=$(jq -r '.proxied_mcps.retry.max_ms // empty' "$BUILD_JSON")
cap=$(jq -r '.proxied_mcps.retry.max_retry_state_entries // empty' "$BUILD_JSON")
if [ -n "$init_ms" ] && [ -n "$max_ms" ] && [ -n "$cap" ]; then
    pass "build.json declares retry.initial_ms=$init_ms, max_ms=$max_ms, max_retry_state_entries=$cap"
else
    fail "build.json .proxied_mcps.retry missing initial_ms / max_ms / max_retry_state_entries"
fi

if grep -qE 'process\.env\.PROXIED_MCPS|loadConfig' "$PROXY_TS" \
   && grep -qE 'initial_ms|max_ms' "$PROXY_TS"; then
    pass "proxy-mcp.ts loads PROXIED_MCPS env + uses declared initial_ms/max_ms"
else
    fail "proxy-mcp.ts doesn't appear to consume build.json retry config"
fi

if grep -qE 'Math\.min.*max_ms|intervalMs\s*\*\s*2' "$PROXY_TS"; then
    pass "exponential doubling capped by max_ms"
else
    fail "proxy-mcp.ts missing exponential doubling against max_ms"
fi

echo ""
echo "── 2: retry-state map is bounded (LRU cap) ──"

if grep -qE 'max_retry_state_entries|retryState\.size\s*>' "$PROXY_TS" \
   && grep -qE 'retryState\.delete|touchRetryEntry' "$PROXY_TS"; then
    pass "retry-state LRU: eviction on size>cap"
else
    fail "retry-state Map is unbounded — OOM regression risk"
fi

echo ""
echo "── 3: single-timer guard across session recreates ──"

if grep -qE 'retryTimer\s*!==\s*null|if\s*\(retryTimer\)' "$PROXY_TS"; then
    pass "retryTimer guard prevents duplicate setInterval on each server recreate"
else
    fail "startProxyRetryLoop may spawn a new setInterval on every call — timer leak"
fi

echo ""
echo "── 4: transport/client cleanup on connect failure ──"

if grep -A6 'await client.connect' "$PROXY_TS" \
   | grep -qE 'transport\.close|client\.close'; then
    pass "failure path closes transport / client"
else
    fail "connect failure does not close transport/client — leaks accumulate"
fi

echo ""
echo "── 5: build.json declares resources + restart_policy ──"

mem=$(jq -r '.containers.app.resources.mem_limit // empty' "$BUILD_JSON")
if [ -n "$mem" ]; then
    pass "containers.app.resources.mem_limit = $mem"
else
    fail "containers.app.resources.mem_limit not declared"
fi

policy=$(jq -r '.containers.app.restart_policy // empty' "$BUILD_JSON")
if [ -n "$policy" ] && [ "$policy" != "no" ]; then
    pass "containers.app.restart_policy = $policy"
else
    fail "containers.app.restart_policy absent or 'no' — crashed service stays dead"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "══════════════════════════════════════════════"
    echo "Phase 9 retry-bounded-backoff: PASS"
    echo "══════════════════════════════════════════════"
    exit 0
else
    echo "══════════════════════════════════════════════"
    echo "Phase 9 retry-bounded-backoff: FAIL"
    echo "══════════════════════════════════════════════"
    exit 1
fi
