#!/usr/bin/env bash
# Tester for sops FRAGMENTS in cloud-ship-container-step-secrets-decrypt.sh (#760).
#
# Contract: src/secrets.<name>.yaml files are merged into the same three
# outputs as src/secrets.yaml (.secrets, .secrets.json, .secrets.d/<KEY>), and
# a key defined in two files fails the step instead of one silently winning.
#
# Sources the REAL step with a stub `sops` that prints the fixture as JSON, so
# no age key is needed and a regression in the step itself is what goes red.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STEP="$ROOT/1_cicd/src/scripts/cloud-ship-container-step-secrets-decrypt.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASSES=0; FAILS=0
ok()  { PASSES=$((PASSES+1)); echo "  ok   $1"; }
bad() { FAILS=$((FAILS+1));  echo "  FAIL $1"; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/sops" <<'EOF'
#!/bin/sh
# stub: `sops -d --output-type json <file>` -> the fixture (already JSON)
for a; do f="$a"; done; cat "$f"
EOF
chmod +x "$TMP/bin/sops"

# run_step <case-dir> — fresh shell, real step, stub sops first on PATH
run_step() {
    PATH="$TMP/bin:$PATH" SRC_DIR="$1/src" DIST_DIR="$1/dist" SERVICE_DIR="$1" \
        bash -c 'log() { echo "[step] $*"; }; . "$0"; step_secrets' "$STEP" > "$1/out" 2>&1
}

# 1: base + fragment merge into all three outputs
C="$TMP/merge"; mkdir -p "$C/src"; echo '{}' > "$C/build.json"
echo '{"A":"one","_credentials":"meta"}' > "$C/src/secrets.yaml"
echo '{"B":"two","_credentials":"own"}'   > "$C/src/secrets.extra.yaml"
if run_step "$C"; then ok "merge: step exits 0"; else bad "merge: step failed"; sed 's/^/    /' "$C/out"; fi
grep -qx 'A=one' "$C/dist/.secrets" && grep -qx 'B=two' "$C/dist/.secrets" \
    && ok "merge: .secrets carries base and fragment keys" || bad "merge: .secrets missing a key"
[ "$(jq -c . "$C/dist/.secrets.json" 2>/dev/null)" = '{"A":"one","B":"two"}' ] \
    && ok "merge: .secrets.json = base + fragment, _-keys filtered" || bad "merge: .secrets.json wrong"
grep -q 'redefines' "$C/out" && bad "merge: both files' _credentials counted as a duplicate" || ok "merge: _credentials in both files is not a duplicate"
[ "$(cat "$C/dist/.secrets.d/B" 2>/dev/null)" = two ] && ok "merge: .secrets.d/B written" || bad "merge: .secrets.d/B missing"

# 2: duplicate key across files -> step fails, names the key, writes nothing
C="$TMP/dup"; mkdir -p "$C/src"; echo '{}' > "$C/build.json"
echo '{"A":"one"}'   > "$C/src/secrets.yaml"
echo '{"A":"other"}' > "$C/src/secrets.extra.yaml"
if run_step "$C"; then bad "dup: step exited 0 on a redefined key"; else ok "dup: step fails"; fi
grep -q 'redefines key(s) already set: A' "$C/out" && ok "dup: names the key" || bad "dup: key not named"
[ ! -e "$C/dist/.secrets" ] && ok "dup: no .secrets written" || bad "dup: .secrets written anyway"

# 3: no fragment -> byte-identical behaviour to before
C="$TMP/plain"; mkdir -p "$C/src"; echo '{}' > "$C/build.json"
echo '{"A":"one"}' > "$C/src/secrets.yaml"
run_step "$C" && [ "$(cat "$C/dist/.secrets")" = 'A=one' ] && ! grep -q 'Merged fragment' "$C/out" \
    && ok "plain: no fragment, unchanged output" || bad "plain: output changed without fragments"

# 4: secrets_backup.yaml is NOT a fragment (underscore, own sops rule)
C="$TMP/backup"; mkdir -p "$C/src"; echo '{}' > "$C/build.json"
echo '{"A":"one"}' > "$C/src/secrets.yaml"
echo '{"Z":"bak"}' > "$C/src/secrets_backup.yaml"
run_step "$C" && ! grep -q '^Z=' "$C/dist/.secrets" && ok "backup: secrets_backup.yaml not merged" || bad "backup: secrets_backup.yaml merged"

echo "test_step_secrets_fragments: $PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
