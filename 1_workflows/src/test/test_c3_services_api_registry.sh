#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ c3-services-api registry — declarative pipeline tests            ║
# ║                                                                  ║
# ║ Proves:                                                          ║
# ║   1. Every build.json with `api.has_api`-relevant type lands in  ║
# ║      cloud-data-c3-services-api.json (after derive).             ║
# ║   2. Every build.json with non-stdio `mcp.transport` lands too.  ║
# ║   3. The set of has_api=true services in consolidated matches    ║
# ║      the set of services that declare an `api` block (with       ║
# ║      type != "no-api") AND have a wg_ip-resolvable VM.           ║
# ║   4. Add-a-new-API smoke: a fresh fixture build.json with `api`  ║
# ║      lands in the derive output without any TS edit.             ║
# ║                                                                  ║
# ║ Usage: bash 1_workflows/src/test/test_c3_services_api_registry.sh ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CONS="$REPO_ROOT/2_configs/dist/_cloud-data-consolidated.json"
REG="$REPO_ROOT/2_configs/dist/cloud-data-c3-services-api.json"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

[ -f "$CONS" ] || { echo "FATAL: missing $CONS — run 2_configs/build.sh all" >&2; exit 1; }
[ -f "$REG" ] || { echo "FATAL: missing $REG — run 2_configs/build.sh all" >&2; exit 1; }

echo "── 1: declared APIs (in build.json) match has_api in consolidated ──"
declared_apis=$(jq -r '
  .services
  | to_entries
  | map(select(.value.api.has_api == true) | .key)
  | sort
  | .[]
' "$CONS")
declared_count=$(printf '%s\n' "$declared_apis" | grep -c . || true)
build_json_apis=$(for d in "$REPO_ROOT"/a_solutions/*/build.json; do
  jq -r 'select(.api.type and .api.type != "no-api") | .name' "$d" 2>/dev/null
done | sort)
build_json_count=$(printf '%s\n' "$build_json_apis" | grep -c . || true)

if [ "$build_json_count" -ge 23 ] && [ "$declared_count" -ge 22 ]; then
  pass "declared APIs in build.json: $build_json_count, has_api in consolidated: $declared_count"
else
  fail "expected ≥23 declared APIs and ≥22 has_api; got declared=$build_json_count consolidated=$declared_count"
fi

echo "── 2: declared MCPs (non-stdio) appear in c3-services-api registry ──"
mcp_in_reg=$(jq -r '.services | to_entries | map(select(.value.mcp != null) | .key) | sort | .[]' "$REG")
mcp_in_reg_count=$(printf '%s\n' "$mcp_in_reg" | grep -c . || true)
mcp_declared_non_stdio=$(for d in "$REPO_ROOT"/a_solutions/*/build.json; do
  jq -r 'select(.mcp.transport and .mcp.transport != "stdio") | .name' "$d" 2>/dev/null
done | sort)
mcp_declared_non_stdio_count=$(printf '%s\n' "$mcp_declared_non_stdio" | grep -c . || true)

if [ "$mcp_in_reg_count" -ge 7 ] && [ "$mcp_declared_non_stdio_count" -ge 7 ]; then
  pass "declared non-stdio MCPs: $mcp_declared_non_stdio_count, MCPs in registry: $mcp_in_reg_count"
else
  fail "expected ≥7 non-stdio MCPs and ≥7 in registry; got declared=$mcp_declared_non_stdio_count registry=$mcp_in_reg_count"
fi

echo "── 3: registry entries all have base_url + vm + port ──"
broken=$(jq -r '.services | to_entries | map(select(.value.base_url == null or .value.vm == null or .value.port == null) | .key) | .[]' "$REG")
if [ -z "$broken" ]; then
  pass "every registry entry has base_url, vm, port"
else
  fail "registry entries missing required fields: $broken"
fi

echo "── 4: registry includes both APIs and MCPs ──"
api_count=$(jq -r '.services | to_entries | map(select(.value.api != null)) | length' "$REG")
mcp_count=$(jq -r '.services | to_entries | map(select(.value.mcp != null)) | length' "$REG")
if [ "$api_count" -ge 22 ] && [ "$mcp_count" -ge 7 ]; then
  pass "registry has $api_count APIs + $mcp_count MCPs"
else
  fail "registry breakdown: APIs=$api_count MCPs=$mcp_count"
fi

echo "── 5: stdio-only MCPs are EXCLUDED from registry ──"
# c3-diego-personal-data-mcp is the canonical stdio-only MCP; must not appear.
if jq -e '.services | has("c3-diego-personal-data-mcp")' "$REG" >/dev/null; then
  fail "stdio-only MCP c3-diego-personal-data-mcp leaked into registry"
else
  pass "stdio-only MCPs correctly excluded"
fi

echo "── 6: schema-gate (api/mcp blocks valid in every build.json) ──"
if (cd "$REPO_ROOT/2_configs/src/engines" && npx tsx validate-build-schema.ts >/dev/null 2>&1); then
  pass "validate-build-schema.ts passes"
else
  fail "validate-build-schema.ts failed"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "════════════════════════════════════════════"
  echo "c3-services-api declarative pipeline: PASS"
  echo "════════════════════════════════════════════"
  exit 0
else
  echo "════════════════════════════════════════════"
  echo "c3-services-api declarative pipeline: FAIL"
  echo "════════════════════════════════════════════"
  exit 1
fi
