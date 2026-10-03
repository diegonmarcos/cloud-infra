#!/usr/bin/env bash
# Test: the home-manager ship deploys when what a VM's build READS changes,
# and the b_infra dist copies of out-of-tree inputs cannot freeze (#662).
#
# #662 (2026-09-30): ship-home-manager's path-relevance gate grepped ^b_infra/.
# The build's real input, 1_cloud-configs/dist/_cloud-data-consolidated.json,
# lives outside b_infra and reaches it through symlinks. A gen-configs commit
# that changed only that file skipped all four VMs in 8 seconds and reported
# green. It normally "worked" only because gen-configs also staged
# b_infra/**/dist copies — which were never regenerated: stale REGULAR files
# where their src counterpart is a symlink (the caddy build-*.json shadow
# trap), frozen at an older schema while looking present and plausible.
#
# Asserts:
#   1. cloud-ship-hm-path-relevance.sh: a consolidated-only change is relevant
#      to every VM; build-vm-<vm>.json only to its VM; an unrelated path to
#      none; a b_infra path reports kind b_infra; an unknown VM fails loud.
#   2. The source workflow uses the helper, not a bare ^b_infra/ grep, and
#      still requires the marker for b_infra changes.
#   3. Every b_infra/**/dist file whose src counterpart resolves outside
#      b_infra/ is a SYMLINK to that same file. A regular-file copy is RED.
#   4. Self-check: a scratch tree with one such copy turned into a regular
#      file makes assertion 3 fail with its message.
set -eu

ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
REL="$ROOT/1_cicd/src/scripts/cloud-ship-hm-path-relevance.sh"
WORKFLOW="$ROOT/1_cicd/src/cicd/ship-home-manager.yml"
CONS="1_cloud-configs/dist/_cloud-data-consolidated.json"
fail=0
ok()  { printf '  ✓ %s\n' "$1"; }
bad() { printf '  ✗ %s\n' "$1" >&2; fail=1; }

vms=$(cd "$ROOT/b_infra" && ls -d nixhm-sudo-* | sed 's/^nixhm-sudo-//')
[ -n "$vms" ] || { echo "FAIL: no b_infra/nixhm-sudo-* VMs found" >&2; exit 1; }

echo "1. path-relevance helper"
for vm in $vms; do
  out=$(printf '%s\n' "$CONS" | HM_RELEVANCE_ROOT="$ROOT" bash "$REL" "$vm" 2>&1) || out="helper exited $?: $out"
  [ "$out" = "input $CONS" ] && ok "$vm: consolidated-only change deploys" || bad "$vm: consolidated-only change did not deploy (got '$out')"
  own="1_cloud-configs/dist/build-vm-$vm.json"
  if [ -e "$ROOT/$own" ]; then
    out=$(printf '%s\n' "$own" | HM_RELEVANCE_ROOT="$ROOT" bash "$REL" "$vm" 2>&1) || out="helper exited $?: $out"
    [ "$out" = "input $own" ] && ok "$vm: own build-vm json deploys" || bad "$vm: own build-vm json did not deploy (got '$out')"
  fi
  out=$(printf 'README.md\n1_cloud-configs/dist/build-vm-not-a-vm.json\n' | HM_RELEVANCE_ROOT="$ROOT" bash "$REL" "$vm" 2>&1) || out="helper exited $?: $out"
  [ -z "$out" ] && ok "$vm: unrelated change skips" || bad "$vm: unrelated change deployed (got '$out')"
  out=$(printf '%s\nb_infra/x.nix\n' "$CONS" | HM_RELEVANCE_ROOT="$ROOT" bash "$REL" "$vm" 2>&1) || out="helper exited $?: $out"
  [ "$out" = "b_infra b_infra/x.nix" ] && ok "$vm: b_infra change reports kind b_infra" || bad "$vm: b_infra kind wrong (got '$out')"
done
if msg=$(echo x | HM_RELEVANCE_ROOT="$ROOT" bash "$REL" no-such-vm 2>&1); then
  bad "unknown VM exited 0 — 'no inputs' would read as 'nothing changed'"
else
  case "$msg" in *"cannot derive what no-such-vm's build reads"*) ok "unknown VM fails loud";; *) bad "unknown VM failed without the expected message: $msg";; esac
fi

echo "2. workflow wiring"
grep -qF 'cloud-ship-hm-path-relevance.sh "$VM"' "$WORKFLOW" && ok "gate calls the helper" || bad "gate does not call cloud-ship-hm-path-relevance.sh"
if grep -qE "grep -E '\^b_infra/'" "$WORKFLOW"; then bad "gate still greps ^b_infra/ (#662)"; else ok "no bare ^b_infra/ grep"; fi
grep -qF '[ "${KIND:-}" != "input" ]' "$WORKFLOW" && ok "marker still required for non-input changes" || bad "marker condition missing"

check_dist_symlinks() { # $1 = root
  local r="$1" bad_n=0 d f rel s rs
  for d in "$r"/b_infra/nixhm-sudo-* "$r"/b_infra/_shared/vm-pilot; do
    [ -d "$d/dist" ] || continue
    while IFS= read -r f; do
      rel="${f#"$d/dist/"}"; s="$d/src/$rel"
      [ -e "$s" ] || continue
      rs=$(realpath "$s")
      case "$rs" in "$r"/b_infra/*) continue;; "$r"/*) ;; *) continue;; esac
      if [ ! -L "$f" ]; then
        printf '  ✗ stale regular-file copy where a symlink is expected: %s (src resolves to %s)\n' "${f#"$r/"}" "${rs#"$r/"}" >&2; bad_n=$((bad_n+1))
      elif [ "$(realpath "$f")" != "$rs" ]; then
        printf '  ✗ dist symlink points elsewhere: %s -> %s (src resolves to %s)\n' "${f#"$r/"}" "$(readlink "$f")" "${rs#"$r/"}" >&2; bad_n=$((bad_n+1))
      fi
    done < <(find "$d/dist" \( -type f -o -type l \))
  done
  return "$bad_n"
}

echo "3. b_infra dist copies of out-of-tree inputs are symlinks"
if check_dist_symlinks "$ROOT"; then ok "all out-of-tree dist inputs are symlinks"; else bad "b_infra dist holds frozen copies"; fi

echo "4. self-check: a regular-file copy goes red"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/1_cloud-configs/dist" "$T/b_infra/nixhm-sudo-vmx/src" "$T/b_infra/nixhm-sudo-vmx/dist"
echo '{"v":2}' > "$T/$CONS"
ln -s "../../../$CONS" "$T/b_infra/nixhm-sudo-vmx/src/c.json"
ln -s "../../../$CONS" "$T/b_infra/nixhm-sudo-vmx/dist/c.json"
check_dist_symlinks "$T" 2>/dev/null && ok "scratch symlink tree passes" || bad "scratch symlink tree failed"
rm "$T/b_infra/nixhm-sudo-vmx/dist/c.json"; echo '{"v":1}' > "$T/b_infra/nixhm-sudo-vmx/dist/c.json"
if msg=$(check_dist_symlinks "$T" 2>&1); then bad "regular-file copy was NOT caught"
else case "$msg" in *"stale regular-file copy where a symlink is expected"*) ok "regular-file copy caught";; *) bad "caught without expected message: $msg";; esac; fi

[ "$fail" -eq 0 ] && echo "PASS" || { echo "FAIL" >&2; exit 1; }
