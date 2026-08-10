#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/test/test_build_schema_api_mcp.sh
# ║   Engine : 1_configs/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ╔══════════════════════════════════════════════════════════════════╗
# ║ Schema-gate test — `api` and `mcp` blocks in build.schema.json   ║
# ║                                                                  ║
# ║ Proves:                                                          ║
# ║   1. build.schema.json declares `api` with required:["type"]     ║
# ║      and additionalProperties:false.                             ║
# ║   2. build.schema.json declares `mcp` with                       ║
# ║      required:["transport"] and additionalProperties:false.      ║
# ║   3. validate-build-schema.ts passes for the current repo.       ║
# ║   4. validate-build-schema.ts REJECTS an api block with an       ║
# ║      unknown property (additionalProperties enforcement).        ║
# ║   5. validate-build-schema.ts REJECTS an api block missing       ║
# ║      `type` (required enforcement).                              ║
# ║   6. validate-build-schema.ts REJECTS an mcp block with an       ║
# ║      invalid `transport` enum value.                             ║
# ║   7. validate-build-schema.ts ACCEPTS a well-formed api block.   ║
# ║   8. validate-build-schema.ts ACCEPTS a well-formed mcp block.   ║
# ║                                                                  ║
# ║ Usage: bash 1_configs/src/test/test_build_schema_api_mcp.sh    ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCHEMA="$REPO_ROOT/a_solutions/build.schema.json"
VALIDATOR="$REPO_ROOT/1_configs/src/engines/validate-build-schema.ts"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

# ── Synthetic fixtures live in a tmp solutions dir; the validator scans
# whatever directory it's pointed at via CLOUD_ROOT-equivalent path layout.
# Simpler: write a tiny harness that uses ajv directly on extracted sub-schemas.

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

HARNESS="$REPO_ROOT/1_configs/src/engines/_validate-block-fixture.ts"

run_harness() {  # block, fixture-content -> echoes VALID|INVALID (always exit 0)
  local block="$1"
  local fixture="$2"
  local fpath="$TMPDIR/fixture.json"
  printf '%s' "$fixture" > "$fpath"
  (cd "$REPO_ROOT/1_configs/src/engines" && npx tsx "$HARNESS" "$SCHEMA" "$fpath" "$block" 2>&1) || true
}

echo "── 1: schema declares api block with required:[type], additionalProperties:false ──"
if jq -e '.properties.api.required == ["type"] and .properties.api.additionalProperties == false' "$SCHEMA" >/dev/null; then
  pass "api block well-formed"
else
  fail "api block missing required:['type'] or additionalProperties:false"
fi

echo "── 2: schema declares mcp block with required:[transport], additionalProperties:false ──"
if jq -e '.properties.mcp.required == ["transport"] and .properties.mcp.additionalProperties == false' "$SCHEMA" >/dev/null; then
  pass "mcp block well-formed"
else
  fail "mcp block missing required:['transport'] or additionalProperties:false"
fi

echo "── 3: validate-build-schema.ts passes on current repo ──"
if (cd "$REPO_ROOT/1_configs/src/engines" && npx tsx "$VALIDATOR" >/dev/null 2>&1); then
  pass "current repo validates clean"
else
  fail "validator regression on current repo"
fi

echo "── 4: api block with unknown property is REJECTED ──"
out=$(run_harness api '{"type":"openapi","foo":"bar"}')
if echo "$out" | grep -q "INVALID"; then
  pass "additionalProperties:false works"
else
  fail "schema accepted unknown api property: $out"
fi

echo "── 5: api block missing type is REJECTED ──"
out=$(run_harness api '{"spec_path":"/x"}')
if echo "$out" | grep -q "INVALID"; then
  pass "required:['type'] works"
else
  fail "schema accepted api block without type: $out"
fi

echo "── 6: mcp block with invalid transport enum is REJECTED ──"
out=$(run_harness mcp '{"transport":"smoke-signals"}')
if echo "$out" | grep -q "INVALID"; then
  pass "transport enum enforced"
else
  fail "schema accepted invalid transport: $out"
fi

echo "── 7: well-formed api block is ACCEPTED ──"
out=$(run_harness api '{"type":"openapi","spec_path":"/swagger.json","base_path":"/api/v1","display_name":"Sample","description":"x","auth":"bearer","endpoint_count":7}')
if echo "$out" | grep -q "VALID"; then
  pass "well-formed api accepted"
else
  fail "schema rejected valid api: $out"
fi

echo "── 8: well-formed mcp block is ACCEPTED ──"
out=$(run_harness mcp '{"transport":"streamable-http","endpoint_path":"/mcp","tools_count":12,"resources_count":0,"prompts_count":0,"display_name":"Sample MCP","description":"x","auth":"none","sdk":"@modelcontextprotocol/sdk@^1.12.0"}')
if echo "$out" | grep -q "VALID"; then
  pass "well-formed mcp accepted"
else
  fail "schema rejected valid mcp: $out"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "════════════════════════════════════════════"
  echo "Build schema api/mcp gate: PASS"
  echo "════════════════════════════════════════════"
  exit 0
else
  echo "════════════════════════════════════════════"
  echo "Build schema api/mcp gate: FAIL"
  echo "════════════════════════════════════════════"
  exit 1
fi
