#!/usr/bin/env bash
# ╔════════════════════════════════════════════════════════════════════╗
# ║ cloud-ship-hm-path-relevance.sh — does a commit change what the    ║
# ║ home-manager build for one VM reads?                               ║
# ║                                                                    ║
# ║ Usage: cloud-ship-hm-path-relevance.sh <vm> < changed-paths        ║
# ║   prints "b_infra <path>"  — a b_infra/ file changed               ║
# ║          "input <path>"    — a file the build reads from OUTSIDE   ║
# ║                              b_infra/ changed (consolidated        ║
# ║                              artifact, build-vm-<vm>.json, ...)    ║
# ║          nothing           — nothing this VM's build reads changed ║
# ║   exits 2 when the VM's input set cannot be derived (fail loud:    ║
# ║   "no inputs found" must never read as "nothing changed").         ║
# ║                                                                    ║
# ║ Why: the gate used to grep ^b_infra/ only. The build's real input, ║
# ║ 1_cloud-configs/dist/_cloud-data-consolidated.json, sits outside   ║
# ║ b_infra and reaches it through symlinks, so a gen-configs commit   ║
# ║ that changed only that file skipped every VM and reported green    ║
# ║ (#662). The out-of-tree input set is DERIVED from those symlinks,  ║
# ║ so a new symlinked input is covered without editing this file.     ║
# ╚════════════════════════════════════════════════════════════════════╝
set -Eeuo pipefail

VM="${1:?vm required as argument 1}"
ROOT="${HM_RELEVANCE_ROOT:-$(git rev-parse --show-toplevel)}"
VM_DIR="b_infra/nixhm-sudo-$VM"

[ -d "$ROOT/$VM_DIR" ] || { echo "::error::path-relevance: $VM_DIR does not exist — cannot derive what $VM's build reads" >&2; exit 2; }

# Out-of-tree inputs: every symlink under the VM's flake dir and the shared
# module trees whose target resolves outside b_infra/. build.sh is the engine
# the build RUNS, not data it reads; engine edits ship through their own path.
inputs=$(
  cd "$ROOT"
  find "$VM_DIR" b_infra/_shared -type l ! -name build.sh 2>/dev/null | while IFS= read -r l; do
    t=$(realpath -m "$l")
    case "$t" in
      "$ROOT"/b_infra/*) ;;
      "$ROOT"/*) printf '%s\n' "${t#"$ROOT"/}" ;;
    esac
  done | sort -u
)
[ -n "$inputs" ] || { echo "::error::path-relevance: no out-of-tree build inputs found for $VM (expected symlinks into 1_cloud-configs/) — refusing to decide" >&2; exit 2; }

hit_b=""; hit_i=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  case "$p" in
    b_infra/*) [ -n "$hit_b" ] || hit_b="$p" ;;
    *) if [ -z "$hit_i" ]; then
         while IFS= read -r i; do
           if [ "$p" = "$i" ] || [ "${p#"$i"/}" != "$p" ]; then hit_i="$p"; break; fi
         done <<< "$inputs"
       fi ;;
  esac
done

if [ -n "$hit_b" ]; then printf 'b_infra %s\n' "$hit_b"
elif [ -n "$hit_i" ]; then printf 'input %s\n' "$hit_i"
fi
