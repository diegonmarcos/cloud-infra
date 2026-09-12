#!/usr/bin/env bash
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

# ── Per-KEY strict override ───────────────────────────────────────────────
# container_readable is declared per service, but a service holds a mix: a
# certificate the non-root user must read, and beside it a private key that
# ssh(1) refuses when it is group/other-readable. The service-wide 0644 used to
# apply to both, with only a comment asking the author not to combine them.
# Now the engine decides per key from the material itself.
strict_for_value() {
    local f="$1"
    if grep -qE 'PRIVATE KEY-----|AGE-SECRET-KEY-1|PuTTY-User-Key-File' "$f" 2>/dev/null; then
        echo strict
    else
        echo loose
    fi
}

printf -- '-----BEGIN RSA PRIVATE KEY-----\nMIIE...\n-----END RSA PRIVATE KEY-----\n' > "$TMP/pem"
check "PEM RSA private key"      "$(strict_for_value "$TMP/pem")"      "strict"
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nb3Bl...\n' > "$TMP/ossh"
check "OpenSSH private key"      "$(strict_for_value "$TMP/ossh")"     "strict"
printf 'AGE-SECRET-KEY-1QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ\n' > "$TMP/age"
check "age identity"             "$(strict_for_value "$TMP/age")"      "strict"
printf 'PuTTY-User-Key-File-3: ssh-rsa\n' > "$TMP/ppk"
check "PuTTY key file"           "$(strict_for_value "$TMP/ppk")"      "strict"

# The other half of the contract: things a container legitimately needs to read
# must NOT be dragged back to 0600, or container_readable stops meaning anything.
printf -- '-----BEGIN CERTIFICATE-----\nMIIF...\n-----END CERTIFICATE-----\n' > "$TMP/crt"
check "certificate stays loose"  "$(strict_for_value "$TMP/crt")"      "loose"
printf -- '-----BEGIN PUBLIC KEY-----\nMFkw...\n' > "$TMP/pub"
check "public key stays loose"   "$(strict_for_value "$TMP/pub")"      "loose"
printf 'hunter2\n' > "$TMP/pw"
check "password stays loose"     "$(strict_for_value "$TMP/pw")"       "loose"
printf '{"token":"abc","note":"no private key here"}\n' > "$TMP/json"
check "json blob stays loose"    "$(strict_for_value "$TMP/json")"     "loose"

# ── Source-level guards ───────────────────────────────────────────────────
# Everything above is a MIRROR of the engine, so on its own it would happily
# stay green after someone deleted the rule from the engine. These two read the
# engine itself. Comments are stripped first: this repo has already shipped a
# guard that was satisfied by its own prose.
ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../1_cicd/src/scripts" && pwd)"
strip_sh_comments() { sed 's/[[:space:]]*#.*$//' "$1"; }

decrypt_src=$(strip_sh_comments "$ENGINE_DIR/cloud-ship-container-step-secrets-decrypt.sh")
if grep -qE 'PRIVATE KEY-----' <<<"$decrypt_src" && grep -q '_kmode=0600' <<<"$decrypt_src"; then
    got=present
else
    got=missing
fi
check "engine enforces per-key strict mode" "$got" "present"

# `scp -r src dest` copies INTO dest when dest already exists, so naming
# "$DEPLOY_PATH/.secrets.d" as the destination made every deploy after the first
# write $DEPLOY_PATH/.secrets.d/.secrets.d/<KEY> — a second copy of every
# credential, one level down, that nothing later rewrote or removed. The
# destination must stay the PARENT directory.
rsync_src=$(strip_sh_comments "$ENGINE_DIR/cloud-ship-container-step-deploy-rsync.sh")
if grep -q 'scp_secret ".secrets.d".*DEPLOY_PATH/\.secrets\.d"' <<<"$rsync_src"; then
    got=nests
else
    got=flat
fi
check "secrets.d scp destination is the parent" "$got" "flat"

if [ "$FAILS" -eq 0 ]; then
    printf 'RESULT: ALL %d ASSERTIONS PASSED\n' "$PASSES"; exit 0
else
    printf 'RESULT: %d FAILED, %d PASSED\n' "$FAILS" "$PASSES"; exit 1
fi
