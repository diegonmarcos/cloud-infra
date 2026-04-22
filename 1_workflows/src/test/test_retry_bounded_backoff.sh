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
# ║ Usage: bash 1_workflows/src/test/test_retry_bounded_backoff.sh   ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SVC_DIR="$REPO_ROOT/a_solutions/bc-obs_c3-services-mcp"
PROXY_TS="$SVC_DIR/src/mcp/tools/proxy-mcp.ts"
BUILD_JSON="$SVC_DIR/build.json"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── 1: exponential backoff state exists ──"

# Look for the three canonical markers of exponential backoff.
if grep -q 'RETRY_INITIAL_MS' "$PROXY_TS" \
   && grep -q 'RETRY_MAX_MS' "$PROXY_TS" \
   && grep -qE 'intervalMs\s*\*\s*2|Math\.min.*intervalMs' "$PROXY_TS"; then
    pass "backoff constants + doubling logic present"
else
    fail "proxy-mcp.ts missing exponential backoff markers (RETRY_INITIAL_MS/RETRY_MAX_MS + doubling)"
fi

# Per-child state map (otherwise one child failing resets everyone's clock).
if grep -q 'retryState' "$PROXY_TS" || grep -q 'Map<string' "$PROXY_TS"; then
    pass "per-child retry state"
else
    fail "proxy-mcp.ts has a single shared retry interval — needs per-child state"
fi

echo ""
echo "── 2: transport/client cleanup on connect failure ──"

if grep -A6 'await client.connect' "$PROXY_TS" \
   | grep -qE 'transport\.close|client\.close'; then
    pass "failure path closes transport / client"
else
    fail "connect failure does not close transport/client — leaks accumulate under upstream outage"
fi

echo ""
echo "── 3: build.json declares resources + restart_policy ──"

mem=$(jq -r '.containers.app.resources.mem_limit // empty' "$BUILD_JSON")
if [ -n "$mem" ]; then
    pass "containers.app.resources.mem_limit = $mem"
else
    fail "containers.app.resources.mem_limit not declared — container will use default (unbounded → host pressure)"
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
