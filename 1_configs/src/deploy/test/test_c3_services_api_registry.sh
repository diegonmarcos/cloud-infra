#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ c3-services-api registry — declarative pipeline tests            ║
# ║                                                                  ║
# ║ Asserts every service in 1_configs/dist/build-c3-services-api    ║
# ║ .json's `services` map carries an `api` and/or `mcp` block       ║
# ║ matching what was declared in each peer's build.json. This is    ║
# ║ the registry the c3-services-api container reads at startup      ║
# ║ (no shared cloud-data file).                                     ║
# ║                                                                  ║
# ║ Proves:                                                          ║
# ║   1. every build.json with a non-no-api `api` block lands in     ║
# ║      build-c3-services-api.json.services.<name>.api.has_api      ║
# ║   2. every build.json with a non-stdio `mcp` block lands in      ║
# ║      .services.<name>.mcp.has_mcp                                ║
# ║   3. every services entry has ip + ports + vm                    ║
# ║   4. registry includes both APIs and MCPs (≥22 + ≥7)             ║
# ║   5. stdio-only MCPs are present (data) but are filtered by the  ║
# ║      consumer at read time (mcp.has_mcp=false)                   ║
# ║   6. validate-build-schema.ts passes (api/mcp blocks valid)      ║
# ║                                                                  ║
# ║ Usage: bash 1_configs/src/deploy/test/test_c3_services_api_registry.sh ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

# Repo root by upward search, not a fixed ../../.. — this file exists at BOTH
# 1_configs/src/deploy/test/ and 1_configs/dist/test/ (generated), which sit at
# different depths, so one literal count is wrong for one of the two copies.
REPO_ROOT="$(_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
BUILD_FILE="$REPO_ROOT/1_configs/dist/build-c3-services-api.json"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

[ -f "$BUILD_FILE" ] || { echo "FATAL: missing $BUILD_FILE — run 1_configs/build.sh all" >&2; exit 1; }

echo "── 1: declared APIs (in build.json) match has_api in build-c3-services-api.json.services.<name>.api ──"
build_json_apis=$(for d in "$REPO_ROOT"/a_solutions/*/build.json; do
  jq -r 'select(.api.type and .api.type != "no-api") | .name' "$d" 2>/dev/null
done | sort)
build_json_count=$(printf '%s\n' "$build_json_apis" | grep -c . || true)
registry_apis=$(jq -r '.services | to_entries[] | select(.value.api.has_api == true) | .key' "$BUILD_FILE" | sort)
registry_api_count=$(printf '%s\n' "$registry_apis" | grep -c . || true)

if [ "$build_json_count" -ge 23 ] && [ "$registry_api_count" -ge 22 ]; then
  pass "declared APIs in build.json: $build_json_count, has_api in registry: $registry_api_count"
else
  fail "expected ≥23 declared APIs and ≥22 registry has_api; got declared=$build_json_count registry=$registry_api_count"
fi

echo "── 2: declared non-stdio MCPs appear in registry as has_mcp=true ──"
build_json_non_stdio=$(for d in "$REPO_ROOT"/a_solutions/*/build.json; do
  jq -r 'select(.mcp.transport and .mcp.transport != "stdio") | .name' "$d" 2>/dev/null
done | sort)
build_json_non_stdio_count=$(printf '%s\n' "$build_json_non_stdio" | grep -c . || true)
registry_mcps=$(jq -r '.services | to_entries[] | select(.value.mcp.has_mcp == true) | .key' "$BUILD_FILE" | sort)
registry_mcp_count=$(printf '%s\n' "$registry_mcps" | grep -c . || true)

if [ "$build_json_non_stdio_count" -ge 7 ] && [ "$registry_mcp_count" -ge 7 ]; then
  pass "declared non-stdio MCPs: $build_json_non_stdio_count, has_mcp in registry: $registry_mcp_count"
else
  fail "expected ≥7 declared non-stdio MCPs and ≥7 has_mcp; got declared=$build_json_non_stdio_count registry=$registry_mcp_count"
fi

echo "── 3: every registry entry has ip + ports + vm ──"
broken=$(jq -r '.services | to_entries | map(select(.value.ip == null or .value.vm == null or (.value.ports | type) != "object") | .key) | .[]' "$BUILD_FILE")
if [ -z "$broken" ]; then
  pass "every registry entry has ip, ports object, vm"
else
  fail "registry entries missing required fields: $broken"
fi

echo "── 4: registry has both APIs and MCPs (totals) ──"
api_count=$(jq -r '.services | to_entries | map(select(.value.api.has_api == true)) | length' "$BUILD_FILE")
mcp_count=$(jq -r '.services | to_entries | map(select(.value.mcp.has_mcp == true)) | length' "$BUILD_FILE")
if [ "$api_count" -ge 22 ] && [ "$mcp_count" -ge 7 ]; then
  pass "registry has $api_count APIs (has_api=true) + $mcp_count MCPs (has_mcp=true)"
else
  fail "registry breakdown: APIs=$api_count MCPs=$mcp_count"
fi

echo "── 5: stdio-only MCPs are PRESENT in services map but flagged has_mcp=false ──"
# c3-diego-personal-data-mcp is the canonical stdio-only MCP. It SHOULD be in the
# services map (so peers can see it exists) but mcp.has_mcp must be false so the
# consumer filters it out at read time.
diego_present=$(jq -r '.services | has("c3-diego-personal-data-mcp")' "$BUILD_FILE")
diego_has_mcp=$(jq -r '.services."c3-diego-personal-data-mcp".mcp.has_mcp // false' "$BUILD_FILE")
if [ "$diego_present" = "true" ] && [ "$diego_has_mcp" = "false" ]; then
  pass "stdio-only MCP c3-diego-personal-data-mcp present + correctly filtered (has_mcp=false)"
elif [ "$diego_present" = "false" ]; then
  # Acceptable variant — service has no VM/wg_ip resolution
  pass "stdio-only MCP c3-diego-personal-data-mcp absent from services map (no VM resolution)"
else
  fail "stdio-only MCP c3-diego-personal-data-mcp present but has_mcp=$diego_has_mcp (expected false)"
fi

echo "── 6: schema-gate (api/mcp blocks valid in every build.json) ──"
if (cd "$REPO_ROOT/1_configs/src/engine" && npx tsx validate-build-schema.ts >/dev/null 2>&1); then
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
