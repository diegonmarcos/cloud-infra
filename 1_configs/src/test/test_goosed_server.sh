#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ goosed server — static source assertions                         ║
# ║                                                                  ║
# ║ Proves:                                                          ║
# ║   A) start.sh launches goose serve with --host 0.0.0.0          ║
# ║   B) start.sh passes --port (GOOSE_PORT or 3227)                 ║
# ║   C) start.sh does NOT pass --tls (plain HTTP, WG-only)          ║
# ║   D) start.sh guards on GOOSE_SERVER__SECRET_KEY                 ║
# ║   E) build.json exposes port 3227 (goosed)                       ║
# ║                                                                  ║
# ║ Usage: bash 1_configs/src/test/test_goosed_server.sh           ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
START_SH="$REPO_ROOT/a_solutions/user-ai_my-ai-api/src/code/start.sh"
BUILD_JSON="$REPO_ROOT/a_solutions/user-ai_my-ai-api/build.json"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── A: start.sh launches goose serve with --host 0.0.0.0 ──"
if grep -q 'goose serve' "$START_SH" && grep -q '\-\-host 0\.0\.0\.0' "$START_SH"; then
    pass "start.sh: goose serve --host 0.0.0.0 present"
else
    fail "start.sh: missing 'goose serve' or '--host 0.0.0.0'"
fi

echo ""
echo "── B: start.sh passes --port with GOOSE_PORT or 3227 ──"
if grep -q '\-\-port' "$START_SH" && grep -E -q 'GOOSE_PORT|3227' "$START_SH"; then
    pass "start.sh: --port with GOOSE_PORT/3227 present"
else
    fail "start.sh: missing --port or GOOSE_PORT/3227 reference"
fi

echo ""
echo "── C: start.sh does NOT pass --tls ──"
if ! grep 'goose serve' "$START_SH" | grep -q '\-\-tls'; then
    pass "start.sh: goose serve invocation has no --tls flag"
else
    fail "start.sh: goose serve passes --tls (must be plain HTTP for WG-only)"
fi

echo ""
echo "── D: start.sh guards on GOOSE_SERVER__SECRET_KEY ──"
if grep -q 'GOOSE_SERVER__SECRET_KEY' "$START_SH"; then
    pass "start.sh: guarded by GOOSE_SERVER__SECRET_KEY"
else
    fail "start.sh: missing GOOSE_SERVER__SECRET_KEY guard"
fi

echo ""
echo "── E: build.json declares port 3227 (goosed) ──"
if jq -e '.ports.goosed == 3227' "$BUILD_JSON" >/dev/null 2>&1; then
    pass "build.json: ports.goosed == 3227"
else
    fail "build.json: ports.goosed is not 3227"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "══════════════════════════════════════════════"
    echo "goosed server: PASS"
    echo "══════════════════════════════════════════════"
    exit 0
else
    echo "══════════════════════════════════════════════"
    echo "goosed server: FAIL"
    echo "══════════════════════════════════════════════"
    exit 1
fi
