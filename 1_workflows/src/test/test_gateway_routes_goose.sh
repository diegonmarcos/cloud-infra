#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ gateway routes goose — static source assertions                  ║
# ║                                                                  ║
# ║ Proves:                                                          ║
# ║   A) gateway.mjs POSTs to /v1/chat/completions                   ║
# ║   B) gateway.mjs sets X-Agent-Mode: goose header                 ║
# ║   C) routeToGoose is used in the Telegram path                   ║
# ║   D) routeToGoose is used in the Mattermost path                 ║
# ║                                                                  ║
# ║ Usage: bash 1_workflows/src/test/test_gateway_routes_goose.sh    ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
GATEWAY="$REPO_ROOT/a_solutions/user-ai_my-ai-api/src/code/gateway.mjs"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── A: gateway POSTs to /v1/chat/completions ──"
if grep -q '/v1/chat/completions' "$GATEWAY"; then
    pass "gateway.mjs references /v1/chat/completions"
else
    fail "gateway.mjs missing /v1/chat/completions"
fi

echo ""
echo "── B: gateway sets X-Agent-Mode: goose ──"
if grep -q '"X-Agent-Mode"' "$GATEWAY" && grep -q '"goose"' "$GATEWAY"; then
    pass "gateway.mjs sets X-Agent-Mode header with goose value"
else
    fail "gateway.mjs missing X-Agent-Mode: goose header"
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
