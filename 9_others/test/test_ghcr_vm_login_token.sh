#!/bin/sh
# GHCR login on deploy VMs must only ever use a LONG-LIVED pull token, and must
# never take a scrubbed placeholder for one.
#
# Incident (2026-10-10, Ship runs 38066044682 / 38073435379): the vault file
# b0-github/api-key_opaque/token had been scrubbed to `***REMOVED***`. step_compose
# tested it with `[ -f ]` only, so every deploy tried to `docker login` with the
# placeholder, failed (a warning), and left oci-apps' deploy user (ubuntu) with no
# ghcr.io credential at all. Private images that were not cached locally —
# kg-store-binaries after a prune — then failed `unauthorized`, and kg-store,
# wireguard-mesh, photoprism and backup-bup failed to deploy.
#
# Checks (EXECUTED against the real function in step-deploy-compose.sh):
#   1. _ghcr_token_usable rejects the placeholder, empty, ghs_ (ephemeral
#      Actions token), short and whitespace-carrying values; accepts ghp_ /
#      github_pat_ PATs.
#   2. GITHUB_TOKEN is never assigned as the VM login token in step_compose.
#   3. GHCR_PULL_TOKEN is forwarded into the cloud-builder by ship.yml.
#   4. The VM-local deploy-user payload is valid bash.
#   5. dist/ copy == header + src/.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC="$ROOT/1_cicd/src/scripts/cloud-ship-container-step-deploy-compose.sh"
DIST="$ROOT/1_cicd/dist/scripts/cloud-ship-container-step-deploy-compose.sh"
SHIP="$ROOT/1_cicd/src/cicd/ship.yml"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; \
       else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }

sed -n '/_ghcr_token_usable() {/,/^    }/p' "$SRC" > "$T/fn.sh"
ck "token shape function found" "$(grep -c '_ghcr_token_usable() {' "$T/fn.sh")" "1"
a36=$(printf 'a%.0s' $(seq 1 36))
try() { bash -c ". '$T/fn.sh'; _ghcr_token_usable \"\$1\" && echo yes || echo no" _ "$1"; }
ck "placeholder ***REMOVED*** rejected"   "$(try '***REMOVED***')" "no"
ck "empty rejected"                       "$(try '')" "no"
ck "ghs_ (GITHUB_TOKEN) rejected"         "$(try "ghs_$a36")" "no"
ck "short ghp_ rejected"                  "$(try 'ghp_abc')" "no"
ck "ghp_ with trailing space rejected"    "$(try "ghp_$a36 ")" "no"
ck "classic PAT accepted"                 "$(try "ghp_$a36")" "yes"
ck "fine-grained PAT accepted"            "$(try "github_pat_${a36}${a36}")" "yes"

ck "GITHUB_TOKEN never becomes the VM login token" \
   "$(grep -cE 'GHCR_TOKEN_VAL="?\$\{?GITHUB_TOKEN' "$SRC" || true)" "0"
ck "ship.yml forwards GHCR_PULL_TOKEN into the builder" \
   "$(grep -c -- '-e GHCR_PULL_TOKEN' "$SHIP")" "2"

sed -n "/_ghcr_ensure_payload='set -u/,/VM-local)\"'/p" "$SRC" | sed 's/^    //' > "$T/p.sh"
bash -c ". '$T/p.sh'; printf '%s\n' \"\$_ghcr_ensure_payload\" > '$T/payload.sh'"
ck "deploy-user payload is valid bash" "$(bash -n "$T/payload.sh" && echo ok)" "ok"
ck "payload never echoes the credential" "$(grep -cE 'echo[^|]*\\\$_(u|r)\b' "$T/payload.sh" || true)" "0"

ck "dist copy == header + src" "$(tail -n +13 "$DIST" | cmp -s - "$SRC" && echo same)" "same"

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
