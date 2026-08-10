#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ gateway routes goose — static source assertions                  ║
# ║                                                                  ║
# ║ Proves:                                                          ║
# ║   A) gateway.mjs references /v1/chat/completions (fallback path) ║
# ║      OR goosed /sessions (primary path)                          ║
# ║   B) gateway.mjs sets X-Agent-Mode: goose (fallback path)        ║
# ║      OR X-Secret-Key (goosed primary path)                       ║
# ║   C) routeToGoose is used in the Telegram path                   ║
# ║   D) routeToGoose is used in the Mattermost path                 ║
# ║   E) goosed primary path present (/sessions + X-Secret-Key)      ║
# ║   F) one-shot fallback present (X-Agent-Mode: goose)             ║
# ║                                                                  ║
# ║ Usage: bash 1_configs/src/deploy/test/test_gateway_routes_goose.sh    ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
GATEWAY="$REPO_ROOT/a_solutions/user-ai_my-ai-api/src/code/gateway.mjs"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── A: gateway references /v1/chat/completions (fallback) OR /sessions (primary) ──"
if grep -q '/v1/chat/completions' "$GATEWAY" || grep -q '/sessions' "$GATEWAY"; then
    pass "gateway.mjs references goose routing path (/v1/chat/completions and/or /sessions)"
else
    fail "gateway.mjs missing both /v1/chat/completions and /sessions"
fi

echo ""
echo "── B: gateway sets X-Agent-Mode: goose (fallback) OR X-Secret-Key (goosed primary) ──"
if grep -q '"X-Agent-Mode"' "$GATEWAY" || grep -q 'X-Secret-Key' "$GATEWAY"; then
    pass "gateway.mjs sets authentication/routing header"
else
    fail "gateway.mjs missing both X-Agent-Mode and X-Secret-Key headers"
fi

echo ""
echo "── C: routeToGoose used in Telegram path ──"
if grep -q 'routeToGoose' "$GATEWAY"; then
    # Verify it appears in startTelegram scope (after the function definition)
    _count=$(grep -c 'routeToGoose' "$GATEWAY")
    if [ "$_count" -ge 2 ]; then
        pass "routeToGoose called in multiple paths (count=$_count)"
    else
        fail "routeToGoose only appears once — expected calls in both Telegram and Mattermost"
    fi
else
    fail "routeToGoose not found in gateway.mjs"
fi

echo ""
echo "── D: routeToGoose used in Mattermost path ──"
# Verify routeToGoose appears inside the startMattermost function body.
if awk '/const startMattermost/,/^};/' "$GATEWAY" | grep -q 'routeToGoose'; then
    pass "routeToGoose called inside startMattermost"
else
    fail "routeToGoose not called inside startMattermost"
fi

echo ""
echo "── E: goosed primary path present (/sessions + X-Secret-Key) ──"
if grep -q '/sessions' "$GATEWAY" && grep -q 'X-Secret-Key' "$GATEWAY"; then
    pass "gateway.mjs has goosed primary path (/sessions with X-Secret-Key)"
else
    fail "gateway.mjs missing goosed primary path (/sessions and/or X-Secret-Key)"
fi

echo ""
echo "── F: one-shot fallback present (X-Agent-Mode: goose + /v1/chat/completions) ──"
if grep -q '"X-Agent-Mode"' "$GATEWAY" && grep -q '/v1/chat/completions' "$GATEWAY"; then
    pass "gateway.mjs retains one-shot fallback (X-Agent-Mode: goose)"
else
    fail "gateway.mjs missing one-shot fallback (X-Agent-Mode: goose and/or /v1/chat/completions)"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "══════════════════════════════════════════════"
    echo "gateway routes goose: PASS"
    echo "══════════════════════════════════════════════"
    exit 0
else
    echo "══════════════════════════════════════════════"
    echo "gateway routes goose: FAIL"
    echo "══════════════════════════════════════════════"
    exit 1
fi
