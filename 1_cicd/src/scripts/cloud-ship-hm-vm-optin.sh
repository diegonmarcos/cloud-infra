#!/usr/bin/env bash
# ╔════════════════════════════════════════════════════════════════════╗
# ║ cloud-ship-hm-vm-optin.sh — may "Ship → home-manager" touch an     ║
# ║ OPT-IN VM on this run?                                             ║
# ║                                                                    ║
# ║ Usage: cloud-ship-hm-vm-optin.sh <vm> <event> [dispatch_vm]        ║
# ║                                  [dispatch_include] < changed-paths║
# ║   HM_OPT_IN_VMS  space-separated opt-in VMs (set in the workflow)  ║
# ║   prints "deploy <reason>" or "skip <reason>", exit 0              ║
# ║   exits 2 on bad usage or when the VM's own input set cannot be    ║
# ║   derived (fail loud, never a silent decision).                    ║
# ║                                                                    ║
# ║ A VM NOT in HM_OPT_IN_VMS always gets "deploy" — the normal gate   ║
# ║ (authorization + path-relevance) decides for it, unchanged.        ║
# ║                                                                    ║
# ║ An opt-in VM ships only when:                                      ║
# ║   workflow_dispatch  dispatch_vm names it, or dispatch_include is  ║
# ║                      "true" (the include_opt_in_vms input);        ║
# ║   push/workflow_run  a changed path is ITS OWN home-manager config:║
# ║                      under b_infra/nixhm-sudo-<vm>/, or the        ║
# ║                      out-of-tree target of one of that dir's own   ║
# ║                      symlinks (1_cloud-configs/dist/build-vm-<vm>  ║
# ║                      .json). Shared inputs — the consolidated      ║
# ║                      artifact, hm-config.json, b_infra/_shared —   ║
# ║                      do NOT count: they change on nearly every     ║
# ║                      gen-configs refresh, which is the storm.      ║
# ║                                                                    ║
# ║ Why (2026-10-13): oci-mail is a 1 OCPU / 954MiB E2.1.Micro. Every  ║
# ║ gen-configs refresh re-shipped the ~2GB nixhm-sudo-oci-mail image  ║
# ║ to it — 6 runs in 3h, each activation 36-64 min on a 1GB VM — on   ║
# ║ top of a mail stack already at load 6-10 and io PSI ~78%.          ║
# ╚════════════════════════════════════════════════════════════════════╝
set -Eeuo pipefail

VM="${1:?vm required as argument 1}"
EVENT="${2:?event name required as argument 2}"
DISPATCH_VM="${3:-}"
DISPATCH_INCLUDE="${4:-false}"
ROOT="${HM_RELEVANCE_ROOT:-$(git rev-parse --show-toplevel)}"

opt_in=false
for v in ${HM_OPT_IN_VMS:-}; do [ "$v" = "$VM" ] && opt_in=true; done
if [ "$opt_in" != true ]; then
  cat >/dev/null   # drain stdin so a writer never sees SIGPIPE
  echo "deploy not-opt-in"
  exit 0
fi

case "$EVENT" in
  workflow_dispatch)
    cat >/dev/null
    if [ "$DISPATCH_VM" = "$VM" ]; then echo "deploy dispatch-targeted"
    elif [ "$DISPATCH_INCLUDE" = "true" ]; then echo "deploy dispatch-include_opt_in_vms"
    else echo "skip opt-in VM not requested (dispatch vm=${DISPATCH_VM:-<all>}, include_opt_in_vms=${DISPATCH_INCLUDE})"
    fi
    exit 0 ;;
  push|workflow_run) ;;
  *) echo "::error::hm-vm-optin: unknown event '$EVENT'" >&2; exit 2 ;;
esac

VM_DIR="b_infra/nixhm-sudo-$VM"
[ -d "$ROOT/$VM_DIR" ] || { echo "::error::hm-vm-optin: $VM_DIR does not exist — cannot derive $VM's own config" >&2; exit 2; }

# The VM's OWN out-of-tree inputs: symlinks in its own dir (not b_infra/_shared)
# resolving outside b_infra/. build.sh is the engine, not config.
own=$(
  cd "$ROOT"
  find "$VM_DIR" -type l ! -name build.sh -not -path '*/dist/*' 2>/dev/null | while IFS= read -r l; do
    t=$(realpath -m "$l")
    case "$t" in
      "$ROOT"/b_infra/*) ;;
      "$ROOT"/*) printf '%s\n' "${t#"$ROOT"/}" ;;
    esac
  done | sort -u
)

while IFS= read -r p; do
  [ -n "$p" ] || continue
  case "$p" in "$VM_DIR"/*) cat >/dev/null; echo "deploy own-config $p"; exit 0 ;; esac
  if [ -n "$own" ] && printf '%s\n' "$own" | grep -qxF -- "$p"; then
    cat >/dev/null; echo "deploy own-input $p"; exit 0
  fi
done

echo "skip opt-in VM: commit touches none of $VM_DIR/ ${own:+or $own}"
