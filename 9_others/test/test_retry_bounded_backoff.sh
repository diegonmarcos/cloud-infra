#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 9 tester — every proxy-mcp retry loop is bounded           ║
# ║                                                                  ║
# ║ Proves:                                                          ║
# ║   proxy-mcp.ts uses per-child exponential backoff + cleans up    ║
# ║   transport + client on connect failure. Absent these two, the   ║
# ║   fixed 30s interval + uncleaned transports grew the Node heap   ║
# ║   past the container's 512 MiB cgroup and OOM-killed the service ║
# ║   every ~75 min (H1 in the 2026-04-21 triage).                   ║
# ║                                                                  ║
# ║   Also asserts build.json declares a memory RESERVATION and a    ║
# ║   restart_policy — otherwise a crash leaves the container dead.  ║
# ║                                                                  ║
# ║   Services are DISCOVERED (any build.json with                   ║
# ║   .proxied_mcps.retry), not hardcoded: this test used to name    ║
# ║   infra-api_c3-services-mcp, which was renamed to                ║
# ║   cloud-services-mcp, so it failed on a missing path instead of  ║
# ║   on anything it asserts — and never covered cloud-mail-mcp's    ║
# ║   proxy at all. Discovery fixes both and survives the next       ║
# ║   rename.                                                        ║
# ║                                                                  ║
# ║ Usage: bash 9_others/test/test_retry_bounded_backoff.sh   ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

# Repo root by upward search, not a fixed ../../.. — this file exists at BOTH
# 9_others/test/ and 1_cicd/dist/test/ (generated), which sit at
# different depths, so one literal count is wrong for one of the two copies.
REPO_ROOT="$(_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

# Discover every service that declares proxied_mcps.retry.
SERVICES=""
for _bj in "$REPO_ROOT"/a_solutions/*/build.json; do
    jq -e '.proxied_mcps.retry' "$_bj" >/dev/null 2>&1 || continue
    SERVICES="$SERVICES $(dirname "$_bj")"
done
[ -n "${SERVICES// /}" ] || { echo "  ✗ no service declares .proxied_mcps.retry — discovery broken" >&2; exit 1; }

check_service() {
  SVC_DIR="$1"
  SVC_NAME="$(basename "$SVC_DIR")"
  echo ""
  echo "════ $SVC_NAME ════"
  # v2 engine cutover (2026-04-22) moved code under src/code/. Both the
  # tools/ and shared/ sub-paths are in use across services.
  PROXY_TS=""
  for _p in \
      "$SVC_DIR/src/code/mcp/tools/proxy-mcp.ts" \
      "$SVC_DIR/src/code/mcp/shared/proxy-mcp.ts" \
      "$SVC_DIR/src/mcp/tools/proxy-mcp.ts"; do
      [ -f "$_p" ] && { PROXY_TS="$_p"; break; }
  done
  [ -z "$PROXY_TS" ] && { fail "$SVC_NAME: proxy-mcp.ts not found under src/code/ or src/"; return 0; }
  BUILD_JSON="$SVC_DIR/build.json"

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

# Match on `client.connect` alone, not `await client.connect`: the call may
# legitimately be wrapped (cloud-mail-mcp wraps it in a withTimeout() race),
# which moves the `await` off the front and made this assert a false failure
# while the cleanup it checks for was present all along.
if grep -A8 'client\.connect' "$PROXY_TS" \
   | grep -qE 'transport\.close|client\.close'; then
    pass "failure path closes transport / client"
else
    fail "connect failure does not close transport/client — leaks accumulate"
fi

echo ""
echo "── 5: build.json declares resources + restart_policy ──"

# A memory RESERVATION (floor), not a limit (ceiling): 9ad4168d2 removed
# limits.memory fleet-wide because cgroup memory.max force-reclaims
# per-container regardless of host free RAM. Asserting mem_limit here
# would demand exactly what that policy deleted.
mem=$(jq -r '.containers.app.resources.mem_reservation // empty' "$BUILD_JSON")
if [ -n "$mem" ]; then
    pass "containers.app.resources.mem_reservation = $mem"
else
    fail "containers.app.resources.mem_reservation not declared"
fi

policy=$(jq -r '.containers.app.restart_policy // empty' "$BUILD_JSON")
if [ -n "$policy" ] && [ "$policy" != "no" ]; then
    pass "containers.app.restart_policy = $policy"
else
    fail "containers.app.restart_policy absent or 'no' — crashed service stays dead"
fi

}

for _svc in $SERVICES; do check_service "$_svc"; done

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
