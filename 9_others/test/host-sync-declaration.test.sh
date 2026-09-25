#!/usr/bin/env bash
# Guards deploy.host_sync (#586): the engine step that copies vault files to a
# host path a service bind-mounts from OUTSIDE its remote_path. Before it,
# c3-public-api's profile bundle mount pointed at a directory nothing ever
# filled — docker pre-created an empty root-owned stub and Profile ▸ Connect
# served nothing while every ship went green.
#
# Proves, on fixtures (no VM, no vault):
#   1  a well-formed entry is read back exactly (name, vault_dir, host_dir, files)
#   2  _doc keys are skipped, not read as entries
#   3  no host_sync at all is a clean no-op (every other service)
#   4  an entry without files[] is RED — the reader errors, never yields a half line
#   5  step_host_sync with a missing source dir FAILS the ship (no silent skip)
#   6  the live declaration in cloud-u-containers/infra-api_c3-public-api agrees
#      with the mount compose.nix declares (skipped, not passed, if that checkout
#      is not beside this repo — #368)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STEP="$ROOT/1_cicd/src/scripts/cloud-ship-container-step-deploy-rsync.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
ok()  { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fail=1; }

# The step file only defines functions; the engine's helpers it calls are
# stubbed here so a failure is the step's own verdict, not a missing stub.
log() { echo "    [log] $1"; }; log_error() { echo "    [error] $1"; }; log_warn() { :; }
ssh_with_retry() { echo "    [ssh $*]"; }; rsync_with_retry() { echo "    [rsync $*]"; }
DEPLOY_HOST="test-vm"
# shellcheck source=/dev/null
. "$STEP"

CONFIG="$TMP/good.json"
cat > "$CONFIG" <<'JSON'
{"deploy":{"host_sync":{"_doc":"skip me","profile_bundle":{"vault_dir":"E0_configs","host_dir":"/home/ubuntu/git/cloud-vault/E0_configs","files":["profile-secrets.json","schema.json"]}}}}
JSON
got="$(host_sync_entries)"
want="$(printf 'profile_bundle\tE0_configs\t/home/ubuntu/git/cloud-vault/E0_configs\tprofile-secrets.json schema.json')"
[ "$got" = "$want" ] && ok "1: entry read back exactly" || bad "1: got '$got'"
[ "$(printf '%s\n' "$got" | wc -l)" = 1 ] && ok "2: _doc is not an entry" || bad "2: _doc leaked as an entry"

CONFIG="$TMP/none.json"; echo '{"deploy":{"host":"x"}}' > "$CONFIG"
[ -z "$(host_sync_entries)" ] && step_host_sync >/dev/null && ok "3: no host_sync is a no-op" || bad "3: a service without host_sync did not pass cleanly"

CONFIG="$TMP/nofiles.json"
echo '{"deploy":{"host_sync":{"b":{"vault_dir":"E0_configs","host_dir":"/x"}}}}' > "$CONFIG"
if host_sync_entries >/dev/null 2>&1; then bad "4: entry without files[] was accepted"; else ok "4: entry without files[] is RED"; fi

CONFIG="$TMP/good.json"
if VAULT_DIR="$TMP/no-vault-here" step_host_sync >"$TMP/out" 2>&1; then bad "5: missing source dir did not fail the ship"
else grep -q 'not on this runner' "$TMP/out" && ok "5: missing source dir fails the ship, named" || bad "5: failed, but not for the missing source: $(cat "$TMP/out")"; fi
mkdir -p "$TMP/vault/E0_configs" && : > "$TMP/vault/E0_configs/profile-secrets.json" && : > "$TMP/vault/E0_configs/schema.json"
if VAULT_DIR="$TMP/vault" step_host_sync >"$TMP/out" 2>&1 && grep -q 'rsync .*profile-secrets.json .*schema.json test-vm:/home/ubuntu/git/cloud-vault/E0_configs/' "$TMP/out"; then
    ok "5b: present sources are rsynced to host_dir"; else bad "5b: $(cat "$TMP/out")"; fi

SVC="$ROOT/../cloud-u-containers/infra-api_c3-public-api"
if [ -f "$SVC/build.json" ]; then
    CONFIG="$SVC/build.json"
    live="$(host_sync_entries)"
    [ -n "$live" ] && ok "6: c3-public-api declares host_sync" || bad "6: c3-public-api has no host_sync — the bundle mount would stay empty"
    grep -q 'buildJson.deploy.host_sync.profile_bundle.host_dir' "$SVC/src/compose.nix" \
        && ok "6: compose.nix mounts the host_sync host_dir (one declaration)" \
        || bad "6: compose.nix does not mount deploy.host_sync.profile_bundle.host_dir"
    jq -e '.profile_connect | has("bundle_host_dir") | not' "$CONFIG" >/dev/null \
        && ok "6: no second bundle_host_dir declaration survives" || bad "6: profile_connect.bundle_host_dir duplicates host_sync.host_dir"
else
    echo "  SKIP  6: cloud-u-containers is not beside this repo — live declaration not cross-checked (unrun, not passed)"
fi
echo "--- host-sync-declaration: $([ $fail = 0 ] && echo GREEN || echo RED)"
exit $fail
