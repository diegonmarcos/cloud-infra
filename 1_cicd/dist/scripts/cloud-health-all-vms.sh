#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_cicd/src/ops/cloud-health-all-vms.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ── Health check every permanent VM in the fleet ──
# Usage: cloud-health-all-vms.sh
#
# This script is NOT dead code. It is registered as the `health_system-resources`
# probe in c3-morpheus (both da_c3-morpheus/data/probes.json and the android
# copy in ac_c3-morpheus/) and shipped as a Dagu DAG asset by infra-obs_dagu.
#
# Debt #20/L5 — it was broken in three independent ways, every one fail-green,
# which together mean this probe has never once health-checked anything:
#
#   1) The GHA branch dispatched health.yml, health-http-public.yml and
#      health-http-private.yml. None of the three exists in .github/workflows/,
#      and none ever has; the only health workflow in the repo is
#      health_mail_full.yml, which covers mail delivery, not VM resources. Each
#      dispatch carried `|| echo WARN` or `|| true`, so `gh` exiting non-zero on
#      an unknown workflow left the script green. There is no VM-resources
#      workflow to repoint at, so the branch is removed rather than rewritten —
#      the direct path below is correct in GHA and on a VM alike, and one code
#      path that runs everywhere cannot rot in the half nobody exercises.
#
#   2) The direct path called cloud-health-check-vm.sh with ONE argument, but
#      that script takes <ssh-alias> AND <ports> and guards the second with
#      `${2:?}`. So every invocation died on the usage guard before opening a
#      single SSH connection, `|| echo "FAIL: $vm"` swallowed the status, and
#      the loop exited 0.
#
#   3) The VM list was hardcoded: "gcp-proxy gcp-t4 oci-apps oci-analytics
#      oci-mail". gcp-t4 has since been retired to z_archive/, and two VMs the
#      list never knew about (gcp-gpu-embed, vast-ollama) have joined the
#      registry. A hardcoded fleet list is wrong the moment the fleet changes,
#      so it is derived below and a new VM is covered the day it is declared.
#
# Scope — which VMs count. The registry's `wg_ip` is the discriminator: the
# permanent mesh members (gcp-proxy, oci-apps, oci-analytics, oci-mail) carry
# one, and the on-demand GPU boxes do not. gcp-gpu-embed is "STOPPED by default
# between runs" and vast-ollama is an ephemeral vast.ai rental, so including
# them would replace a permanently-green probe with a permanently-red one,
# which is no more useful. Derived, not listed: a new mesh VM is picked up
# automatically, and a GPU box stays out without being named here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# Fleet registry — ssh_alias, wg_ip and public_ports per VM. CLOUD_DATA_JSON
# lets a caller that already has the file (the MCP container bakes it at /app)
# point straight at it.
CLOUD_DATA_JSON="${CLOUD_DATA_JSON:-}"
if [ -z "$CLOUD_DATA_JSON" ]; then
    for _candidate in \
        "/app/_cloud-data-consolidated.json" \
        "$REPO_ROOT/1_cloud-configs/dist/_cloud-data-consolidated.json"; do
        [ -f "$_candidate" ] && { CLOUD_DATA_JSON="$_candidate"; break; }
    done
fi
if [ ! -f "$CLOUD_DATA_JSON" ]; then
    echo "::error::fleet registry not found — set CLOUD_DATA_JSON to _cloud-data-consolidated.json" >&2
    exit 1
fi

# One "<ssh_alias><TAB><comma-separated ports>" line per permanent VM. The port
# list may be empty: a VM with no declared public_ports has nothing to
# port-check, and cloud-health-check-vm.sh then checks containers only.
VM_LINES="$(jq -r '
    .vms
    | to_entries[]
    | .value
    | select(.ssh_alias and .wg_ip)
    | [ .ssh_alias,
        ([ .public_ports[]?.port ] | unique | map(tostring) | join(","))
      ]
    | @tsv
' "$CLOUD_DATA_JSON")"

if [ -z "$VM_LINES" ]; then
    echo "::error::registry declares no permanent VMs (ssh_alias + wg_ip) — refusing to report healthy" >&2
    exit 1
fi

# Collect failures rather than aborting on the first: one unreachable VM must
# not hide the state of the other three. But DO fail at the end — reporting
# green while every check failed is the defect this script existed to have.
FAILED=""
CHECKED=0
while IFS="$(printf '\t')" read -r vm_alias vm_ports; do
    [ -n "$vm_alias" ] || continue
    echo "── Health: $vm_alias ──"
    CHECKED=$((CHECKED + 1))
    if ! bash "$SCRIPT_DIR/cloud-health-check-vm.sh" "$vm_alias" "$vm_ports"; then
        FAILED="$FAILED $vm_alias"
    fi
done <<VMS
$VM_LINES
VMS

echo ""
if [ -n "$FAILED" ]; then
    echo "::error::unhealthy VM(s):$FAILED"
    exit 1
fi
echo "All $CHECKED VM(s) healthy"
