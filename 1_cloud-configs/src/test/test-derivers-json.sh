#!/usr/bin/env bash
# ===========================================================================
# test-derivers-json.sh — assert 1_cloud-configs/src/derivers.json is well-formed
# and every script it lists exists on disk + the engine actually iterates it.
# ===========================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DJ="$ROOT/src/derivers.json"
BS="$ROOT/build.sh"

pass=0; fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
nope() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }

echo "▶ derivers.json integrity"

# ── Phase 1 · file present + JSON parses ─────────────────────────────────
[ -f "$DJ" ] && ok "derivers.json present"            || { nope "derivers.json missing"; exit 1; }
jq -e . "$DJ" >/dev/null 2>&1 && ok "valid JSON"      || nope "JSON parse error"

# ── Phase 2 · schema ─────────────────────────────────────────────────────
schema=$(jq -r '._schema // empty' "$DJ")
[ "$schema" = "derivers/v1" ] && ok "_schema = $schema" || nope "_schema=$schema (expected derivers/v1)"

count=$(jq '.derivers | length' "$DJ")
[ "$count" -ge 1 ] && ok ".derivers has $count entries" || nope "no derivers declared"

# Every entry has name + script; every script file exists.
i=0
while [ "$i" -lt "$count" ]; do
  name=$(jq -r ".derivers[$i].name   // empty" "$DJ")
  rel=$( jq -r ".derivers[$i].script // empty" "$DJ")
  [ -n "$name" ] && ok "[$i] name = $name"   || nope "[$i] name missing"
  [ -n "$rel"  ] && ok "[$i] script = $rel"  || nope "[$i] script missing"
  if [ -n "$rel" ]; then
    [ -f "$ROOT/$rel" ] && ok "[$i] script exists on disk" \
                        || nope "[$i] script not found at $ROOT/$rel"
  fi
  i=$((i + 1))
done

# ── Phase 3 · derive-mesh-snapshot is registered ─────────────────────────
jq -e '.derivers[] | select(.name == "mesh-snapshot")' "$DJ" >/dev/null \
  && ok "mesh-snapshot deriver registered" \
  || nope "mesh-snapshot deriver NOT in derivers.json"

# ── Phase 4 · build.sh actually iterates derivers.json (not hardcoded) ──
grep -q 'src/derivers.json' "$BS" \
  && ok "build.sh references src/derivers.json" \
  || nope "build.sh does NOT iterate derivers.json — hardcoded list (fire-rule 6 violation)"

grep -q 'jq.*\.derivers' "$BS" \
  && ok "build.sh iterates .derivers via jq" \
  || nope "build.sh missing jq iteration of .derivers"

echo
if [ "$fail" = 0 ]; then
  printf '▶ \033[32m%d passed, 0 failed\033[0m\n' "$pass"
  exit 0
else
  printf '▶ \033[31m%d passed, %d failed\033[0m\n' "$pass" "$fail"
  exit 1
fi
