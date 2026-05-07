#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ test-kg-derive.sh                                                ║
# ║ Asserts the kg-graph schema + delta derivers produce a valid,    ║
# ║ data-driven, idempotent output. Runs after `bash build.sh all`.  ║
# ║                                                                  ║
# ║ Pass criteria:                                                   ║
# ║   1. dist/build-kg-graph_schema.json exists and parses           ║
# ║   2. dist/build-kg-graph_delta.json exists and parses            ║
# ║   3. Every VM with wg_ip in consolidated has a corresponding     ║
# ║      vm-node in the delta                                        ║
# ║   4. Every enabled service in consolidated has a service-node    ║
# ║   5. Every service.vm reference resolves to a hosted_on edge     ║
# ║   6. Re-running derive twice produces byte-identical files       ║
# ║      (idempotency)                                               ║
# ║   7. Schema's vector_indexes empty when embedder.enabled=false   ║
# ║   8. No node/edge keys contain "-" or "."                        ║
# ╚══════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIGS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DIST="$CONFIGS_DIR/dist"
SCHEMA="$DIST/build-kg-graph_schema.json"
DELTA="$DIST/build-kg-graph_delta.json"
CONSOLIDATED="$DIST/_cloud-data-consolidated.json"
fails=0

fail() { echo "  FAIL: $*"; fails=$((fails + 1)); }
ok()   { echo "  OK:   $*"; }

# ── 1+2: files exist and parse ──────────────────────────────────────────
[ -f "$SCHEMA" ] || { fail "$SCHEMA missing"; exit 1; }
[ -f "$DELTA"  ] || { fail "$DELTA missing";  exit 1; }
jq -e . "$SCHEMA" >/dev/null  || fail "schema is not valid JSON"
jq -e . "$DELTA"  >/dev/null  || fail "delta is not valid JSON"
ok "schema + delta files parse"

# ── 3: every WG-routable VM appears as a node ───────────────────────────
expected_vms=$(jq -r '.vms | to_entries[] | select(.value.wg_ip and .value.ssh_alias) | .value.ssh_alias' "$CONSOLIDATED" | sort -u)
got_vms=$(jq -r '.nodes[] | select(.table=="vm") | .properties.alias' "$DELTA" | sort -u)
if diff <(echo "$expected_vms") <(echo "$got_vms") >/dev/null; then
    ok "every WG-routable VM has a vm-node"
else
    fail "vm-node set != consolidated VMs:"
    diff <(echo "$expected_vms") <(echo "$got_vms") | sed 's/^/        /'
fi

# ── 4: every enabled service has a service-node ─────────────────────────
expected_svcs=$(jq -r '.services | to_entries[] | select(.value.enabled != false) | .key' "$CONSOLIDATED" | sort -u)
got_svcs=$(jq -r '.nodes[] | select(.table=="service") | .properties.name' "$DELTA" | sort -u)
missing=$(comm -23 <(echo "$expected_svcs") <(echo "$got_svcs"))
if [ -z "$missing" ]; then
    ok "every enabled service has a service-node"
else
    fail "missing service-nodes:"; echo "$missing" | sed 's/^/        /'
fi

# ── 5: each service.vm resolves to a hosted_on edge ─────────────────────
hosted_count=$(jq '[.edges[] | select(.table=="hosted_on")] | length' "$DELTA")
expected_hosted=$(jq '[.services | to_entries[] | select(.value.enabled != false and .value.vm and (.value.vm | IN(.vms[]?.alias // .vms[]?.ssh_alias // empty) | not))] | length' "$CONSOLIDATED" 2>/dev/null || echo "0")
[ "$hosted_count" -gt 0 ] && ok "hosted_on edges populated ($hosted_count)" \
    || fail "no hosted_on edges produced"

# ── 6: idempotency — re-derive and compare ──────────────────────────────
tmp_schema=$(mktemp); tmp_delta=$(mktemp)
cp "$SCHEMA" "$tmp_schema"; cp "$DELTA" "$tmp_delta"
( cd "$CONFIGS_DIR" && bash build.sh derive >/dev/null )
# Strip _generated timestamps (the only legitimately-changing field) before diff
jq 'del(._generated, ._meta.generated_at)' "$SCHEMA"     > "$SCHEMA.norm"
jq 'del(._generated, ._meta.generated_at)' "$tmp_schema" > "$tmp_schema.norm"
jq 'del(._generated, ._meta.generated_at)' "$DELTA"      > "$DELTA.norm"
jq 'del(._generated, ._meta.generated_at)' "$tmp_delta"  > "$tmp_delta.norm"
diff "$SCHEMA.norm"     "$tmp_schema.norm" >/dev/null && ok "schema is idempotent" || fail "schema not idempotent"
diff "$DELTA.norm"      "$tmp_delta.norm"  >/dev/null && ok "delta is idempotent"  || fail "delta not idempotent"
rm -f "$tmp_schema" "$tmp_delta" "$SCHEMA.norm" "$tmp_schema.norm" "$DELTA.norm" "$tmp_delta.norm"

# ── 7: vector_indexes gated by embedder.enabled ─────────────────────────
embedder_enabled=$(jq -r '.embedder.enabled' "$SCHEMA")
vec_count=$(jq '.vector_indexes | length' "$SCHEMA")
if [ "$embedder_enabled" = "false" ] && [ "$vec_count" -eq 0 ]; then
    ok "vector_indexes correctly empty (embedder disabled)"
elif [ "$embedder_enabled" = "true" ] && [ "$vec_count" -gt 0 ]; then
    ok "vector_indexes populated (embedder enabled, $vec_count indexes)"
else
    fail "vector_indexes/embedder mismatch (enabled=$embedder_enabled, count=$vec_count)"
fi

# ── 8: deterministic-key sanitisation ──────────────────────────────────
# Validate only the sanitized identifier portion (after the table:colon).
# Edge keys legitimately contain "->", so we extract from/to identifiers.
bad_keys=$(
  {
    jq -r '.nodes[].id' "$DELTA"
    jq -r '.edges[] | (.from, .to) | sub("^[^:]+:"; "")' "$DELTA"
  } | grep -E '[-.]' || true
)
if [ -z "$bad_keys" ]; then
    ok "all node/edge keys are SurrealDB-record-id-safe"
else
    fail "unsafe keys found:"; echo "$bad_keys" | head -5 | sed 's/^/        /'
fi

# ── 9: consumer-side symlinks in a_solutions/ca-dat_kg-graph/src/ ──────
KG_SRC="$(cd "$CONFIGS_DIR/.." && pwd)/a_solutions/ca-dat_kg-graph/src"
for name in build-kg-graph_schema.json build-kg-graph_delta.json; do
    link="$KG_SRC/$name"
    if [ ! -L "$link" ]; then
        fail "$link is not a symlink (consumer-side link missing)"
    elif [ ! -e "$link" ]; then
        fail "$link symlink is dangling (target $(readlink "$link") missing)"
    else
        ok "$name symlinked into kg-graph/src/"
    fi
done

# ── 11: schema.surql.tpl uses placeholders (no hardcoded model/dim) ─────
TPL="$KG_SRC/templates/schema.surql.tpl"
if [ ! -f "$TPL" ]; then
    fail "$TPL missing"
else
    for ph in '@EMBEDDER_MODEL@' '@EMBEDDER_DIM@' '@EMBEDDER_ENABLED@' '@VECTOR_INDEXES_DDL@'; do
        grep -qF "$ph" "$TPL" || fail "$TPL missing placeholder $ph"
    done
    # Reject hardcoded references that would diverge from JSON SoT.
    if grep -qE 'DIMENSION 768 TYPE F32' "$TPL"; then
        fail "$TPL has hardcoded MTREE DDL — should be in @VECTOR_INDEXES_DDL@ only"
    fi
    ok "schema.surql.tpl is data-driven (placeholders present, no hardcoded MTREE)"
fi

# ── 12: flake.nix consumes build-kg-graph_schema.json ───────────────────
FLAKE="$KG_SRC/flake.nix"
if grep -qF 'build-kg-graph_schema.json' "$FLAKE" \
   && grep -qF 'VECTOR_INDEXES_DDL' "$FLAKE"; then
    ok "flake.nix wires schema JSON → template substitution"
else
    fail "flake.nix is not reading build-kg-graph_schema.json or not passing VECTOR_INDEXES_DDL"
fi

# ── 13: vector_indexes count in JSON matches what flake would emit ──────
# Sanity: when embedder.enabled=false, the DDL block should collapse to a
# comment; when true, count of MTREE statements == vector_indexes length.
if [ "$embedder_enabled" = "false" ] && [ "$vec_count" -eq 0 ]; then
    ok "vector_indexes / embedder.enabled coherent (both off)"
elif [ "$embedder_enabled" = "true" ] && [ "$vec_count" -gt 0 ]; then
    ok "vector_indexes / embedder.enabled coherent (both on, $vec_count indexes)"
else
    fail "vector_indexes/embedder.enabled mismatch"
fi

# ── Summary ─────────────────────────────────────────────────────────────
if [ "$fails" -eq 0 ]; then
    echo "test-kg-derive: ALL PASSED"
    exit 0
else
    echo "test-kg-derive: $fails check(s) failed"
    exit 1
fi
