#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/test/test_step_secrets_container_readable.sh
# ║   Engine : 1_configs/src/gha/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Unit test for the data-driven .secrets.d/ permission selection in
# cloud-ship-container-step-secrets-decrypt.sh.
#
# Contract: build.json .secrets.container_readable decides the mode of the
# bind-mounted .secrets.d/ dir + per-key files:
#   true            → dir 0755 / files 0644  (non-root container user can read)
#   false / absent  → dir 0700 / files 0600  (strict; ssh -i keys refuse looser)
#
# Mirrors the exact selection expression from the engine step. If the engine's
# expression changes, update BOTH here and there.
set -euo pipefail

# The selection under test (byte-identical to the engine step):
select_modes() {
    local build_json="$1"
    local _cr
    _cr=$(jq -r '.secrets.container_readable // false' "$build_json" 2>/dev/null || echo false)
    if [ "$_cr" = "true" ]; then echo "0755 0644"; else echo "0700 0600"; fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILS=0; PASSES=0
check() { if [ "$2" = "$3" ]; then PASSES=$((PASSES+1)); else printf 'FAIL: %s → got [%s] want [%s]\n' "$1" "$2" "$3"; FAILS=$((FAILS+1)); fi; }

# Case 1: container_readable=true → loose
printf '{"secrets":{"container_readable":true}}' > "$TMP/a.json"
check "container_readable=true" "$(select_modes "$TMP/a.json")" "0755 0644"

# Case 2: container_readable=false → strict
printf '{"secrets":{"container_readable":false}}' > "$TMP/b.json"
check "container_readable=false" "$(select_modes "$TMP/b.json")" "0700 0600"

# Case 3: secrets present, flag absent → strict default
printf '{"secrets":{"escape_dollars":true}}' > "$TMP/c.json"
check "flag absent (secrets obj)" "$(select_modes "$TMP/c.json")" "0700 0600"

# Case 4: no secrets object at all → strict default
printf '{"name":"x"}' > "$TMP/d.json"
check "no secrets object" "$(select_modes "$TMP/d.json")" "0700 0600"

# Case 5: missing/garbage build.json → strict default (fail-closed)
check "missing build.json" "$(select_modes "$TMP/does-not-exist.json")" "0700 0600"

if [ "$FAILS" -eq 0 ]; then
    printf 'RESULT: ALL %d ASSERTIONS PASSED\n' "$PASSES"; exit 0
else
    printf 'RESULT: %d FAILED, %d PASSED\n' "$FAILS" "$PASSES"; exit 1
fi
