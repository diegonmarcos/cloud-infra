#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_cicd/src/scripts/cloud-ship-ci-ssh-config.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ╔══════════════════════════════════════════════════════════════════╗
# ║ Render a CI ssh config from the fleet DECLARATIONS                ║
# ║                                                                  ║
# ║ The VM → mesh IP → user → key table is declared exactly once, in  ║
# ║ 1_cloud-configs/dist/build-gha.json (derived from config.json's   ║
# ║ vms[*].gha block). Every workflow that needs to reach a VM reads  ║
# ║ it from here instead of restating it.                            ║
# ║                                                                  ║
# ║ Why this file exists (#20 / L8): health_mail_full.yml,            ║
# ║ cloud-health-reports.yml and cloud-health-reports-arm-oci-apps.yml║
# ║ each carried their own hand-written copy of that table. Three     ║
# ║ copies means two of them are whichever one nobody edits — and a   ║
# ║ health workflow pointed at a stale IP reports on a host that no   ║
# ║ longer exists. It goes green and it verified nothing, which is    ║
# ║ the same failure the workflow was written to catch.               ║
# ║ ship-reconcile.yml already read the declarations; this is that    ║
# ║ same logic extracted so there is ONE renderer, not four.          ║
# ║                                                                  ║
# ║ Inputs (environment):                                            ║
# ║   SSH_CONFIG_DIR    where config + key files are written          ║
# ║                     (default: $HOME/.ssh)                         ║
# ║   SSH_IDENTITY_DIR  path IdentityFile points at, for when the     ║
# ║                     directory is mounted elsewhere — the reports  ║
# ║                     container sees it as /root/.ssh               ║
# ║                     (default: same as SSH_CONFIG_DIR)             ║
# ║   GHA_CONFIG        declaration to read                           ║
# ║                     (default: 1_cloud-configs/dist/build-gha.json)║
# ║   <ssh_secret>      one env var per declared key, named by the    ║
# ║                     vms[*].gha.ssh_secret value (OCI_SSH_KEY, …), ║
# ║                     carrying the private key. A VM whose secret   ║
# ║                     is absent from the environment is skipped —   ║
# ║                     that is how one workflow gets the OCI hosts   ║
# ║                     only and another gets all of them, without    ║
# ║                     either one listing hosts by hand.             ║
# ║                                                                  ║
# ║ Usage: bash 1_cicd/src/scripts/cloud-ship-ci-ssh-config.sh        ║
# ╚══════════════════════════════════════════════════════════════════╝
set -euo pipefail

SSH_CONFIG_DIR="${SSH_CONFIG_DIR:-$HOME/.ssh}"
SSH_IDENTITY_DIR="${SSH_IDENTITY_DIR:-$SSH_CONFIG_DIR}"
GHA_CONFIG="${GHA_CONFIG:-1_cloud-configs/dist/build-gha.json}"

command -v jq >/dev/null 2>&1 || { echo "::error::jq is required by $0"; exit 1; }
[ -f "$GHA_CONFIG" ] || { echo "::error::$GHA_CONFIG not found — it is generated; run ./build.sh config"; exit 1; }

mkdir -p "$SSH_CONFIG_DIR"
: > "$SSH_CONFIG_DIR/config"
chmod 600 "$SSH_CONFIG_DIR/config"

# The secret NAME becomes the key FILE name by one stated rule: lowercase, and a
# trailing `_ssh_key` collapses to `_key`. OCI_SSH_KEY → oci_key,
# GCP_PROXY_SSH_KEY → gcp_proxy_key — the names the workflows already used, so
# nothing that mounts this directory sees a rename. No lookup table, so adding a
# VM to the declarations needs no edit here.
key_file_for() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/_ssh_key$/_key/'; }

_hosts=0
_skipped=""
while IFS="$(printf '\t')" read -r alias ip user secret; do
    [ -n "$alias" ] || continue

    # Indirect expansion: the declaration names the env var, the environment
    # carries its value. A VM whose key was not passed in is not reachable from
    # this job, so it is left out of the config rather than given a Host entry
    # that would hang on every connection.
    key_material="${!secret:-}"
    if [ -z "$key_material" ]; then
        _skipped="$_skipped $alias($secret)"
        continue
    fi

    _kf="$(key_file_for "$secret")"
    if [ ! -f "$SSH_CONFIG_DIR/$_kf" ]; then
        printf '%s\n' "$key_material" > "$SSH_CONFIG_DIR/$_kf"
        chmod 600 "$SSH_CONFIG_DIR/$_kf"
    fi

    {
        echo "Host $alias"
        echo "  HostName $ip"
        echo "  User $user"
        echo "  IdentityFile $SSH_IDENTITY_DIR/$_kf"
        echo "  StrictHostKeyChecking no"
        echo "  BatchMode yes"
        echo "  ConnectTimeout 15"
    } >> "$SSH_CONFIG_DIR/config"
    _hosts=$((_hosts + 1))
done < <(jq -r '.vms | to_entries[]
                | select(.value.wg_ip != null and .value.ssh_secret != null)
                | [.key, .value.wg_ip, (.value.user // "ubuntu"), .value.ssh_secret]
                | @tsv' "$GHA_CONFIG")

# A config with zero Host entries is the vacuous-pass shape: every later ssh
# fails with "Could not resolve hostname", the step that swallows it reports
# nothing, and the job is green having checked no VM at all. Fail here instead.
if [ "$_hosts" -eq 0 ]; then
    echo "::error::ssh config rendered 0 hosts from $GHA_CONFIG. Either the declaration has no VM with both wg_ip and gha.ssh_secret, or no key secret was passed to this step. Skipped:${_skipped:- none}"
    exit 1
fi

[ -n "$_skipped" ] && echo "::notice::ssh config skipped (no key in this job's environment):$_skipped"
echo "ssh config covers $_hosts VM(s): $(grep '^Host ' "$SSH_CONFIG_DIR/config" | cut -d' ' -f2 | tr '\n' ' ')"
