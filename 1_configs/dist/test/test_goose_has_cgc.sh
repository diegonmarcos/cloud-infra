#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/deploy/test/test_goose_has_cgc.sh
# ║   Engine : 1_configs/src/deploy/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ╔══════════════════════════════════════════════════════════════════╗
# ║ goose config has cgc — static YAML assertions                    ║
# ║                                                                  ║
# ║ Proves:                                                          ║
# ║   A) goose-config.yaml references cloud-cgc-mcp MCP endpoint    ║
# ║   B) goose-config.yaml sets provider base at 127.0.0.1:3217     ║
# ║                                                                  ║
# ║ Usage: bash 1_configs/src/deploy/test/test_goose_has_cgc.sh           ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

# Repo root by upward search, not a fixed ../../.. — this file exists at BOTH
# 1_configs/src/deploy/test/ and 1_configs/dist/test/ (generated), which sit at
# different depths, so one literal count is wrong for one of the two copies.
REPO_ROOT="$(_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
CONFIG="$REPO_ROOT/a_solutions/user-ai_my-ai-api/src/code/configs/goose-config.yaml"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── A: cloud-cgc-mcp endpoint in goose config ──"
if grep -q 'http://10.0.0.6:3105/mcp' "$CONFIG"; then
    pass "goose-config.yaml contains cloud-cgc-mcp URI http://10.0.0.6:3105/mcp"
else
    fail "goose-config.yaml missing cloud-cgc-mcp URI http://10.0.0.6:3105/mcp"
fi

echo ""
echo "── B: provider base points at 127.0.0.1:3217 ──"
if grep -q '127.0.0.1:3217' "$CONFIG"; then
    pass "goose-config.yaml contains local my-ai-api base http://127.0.0.1:3217"
else
    fail "goose-config.yaml missing local base http://127.0.0.1:3217"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "══════════════════════════════════════════════"
    echo "goose config has cgc: PASS"
    echo "══════════════════════════════════════════════"
    exit 0
else
    echo "══════════════════════════════════════════════"
    echo "goose config has cgc: FAIL"
    echo "══════════════════════════════════════════════"
    exit 1
fi
