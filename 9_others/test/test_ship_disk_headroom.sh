#!/usr/bin/env bash
# The ship refuses to deploy onto a VM with no room, BEFORE touching any container.
#
# Ship 38998754151 (2026-10-17): oci-apps' root hit 100% (61 MB free) mid-deploy; 26 of 59
# services failed "No space left on device" and google-workspace-mcp was left half-recreated.
# cloud-ship-disk-headroom.sh measures free space first, prunes DANGLING images only if it is
# under the floor, and fails fast if that is not enough. ssh is stubbed: no VM, no network.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(_d="$SCRIPT_DIR"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
LIB="$REPO_ROOT/1_cicd/src/scripts/cloud-ship-disk-headroom.sh"
[ -f "$LIB" ] || { echo "FAIL: $LIB missing"; exit 1; }
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1: expected '$3', got '$2'"; fi; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir "$W/bin"
cat > "$W/bin/ssh" <<'STUB'
#!/usr/bin/env bash
# last argument is the remote command; df answers come from $W/free (one value per line, consumed in order)
cmd="${@: -1}"
echo "$cmd" >> "$STUB_LOG"
case "$cmd" in
  df*) if [ -s "$STUB_FREE" ]; then v="$(head -1 "$STUB_FREE")"; sed -i 1d "$STUB_FREE"; [ "$v" = "FAIL" ] && exit 255; printf '%s' "$v"; else exit 255; fi ;;
  "docker image prune -f") exit 0 ;;
  *) echo "UNEXPECTED REMOTE COMMAND: $cmd" >> "$STUB_LOG"; exit 9 ;;
esac
STUB
chmod +x "$W/bin/ssh"
export PATH="$W/bin:$PATH" STUB_LOG="$W/log" STUB_FREE="$W/free"
log() { :; }; log_error() { :; }

run() { # $1=free values (space separated) ; $2.. = extra args to the guard
  : > "$STUB_LOG"; printf '%s\n' $1 > "$STUB_FREE"; shift
  # shellcheck disable=SC1090
  ( . "$LIB"; ship_disk_headroom_guard vm-x "$@" ); echo $?
}
prunes() { grep -c '^docker image prune -f$' "$STUB_LOG"; }

ck "plenty of room -> proceed"              "$(run "40")"            "0"; ck "  ... and nothing was pruned" "$(prunes)" "0"
ck "low, prune frees enough -> proceed"     "$(run "2 9")"           "0"; ck "  ... pruned exactly once"    "$(prunes)" "1"
ck "low, prune is not enough -> REFUSE"     "$(run "0 1")"           "1"; ck "  ... it did try the prune"   "$(prunes)" "1"
ck "VM unreadable -> do not block the ship" "$(run "FAIL")"          "0"
ck "unreadable after the prune -> continue" "$(run "1 FAIL")"        "0"
ck "floor is configurable (3 GB free, floor 4)" "$(run "3 3" 4)"     "1"
ck "SHIP_MIN_FREE_GB=0 disables the guard"  "$(SHIP_MIN_FREE_GB=0 run "0")" "0"; ck "  ... and measures nothing"   "$(wc -l < "$STUB_LOG" | tr -d ' ')" "0"
ck "only dangling images are ever pruned"   "$(grep -c -E 'prune -a|system prune|rmi|volume' "$STUB_LOG")" "0"
ck "no unexpected remote command was issued" "$(grep -c UNEXPECTED "$STUB_LOG")" "0"

# the big per-VM floor applies to full ships only
eff() { ( . "$LIB"; ship_effective_floor "$@" ); }
ck "full ship (59 services) gets the VM floor"      "$(eff 59 12)"  "12"
ck "scoped ship (1 service) gets the default 5"     "$(eff 1 12)"   "5"
ck "7 services is still scoped, 8 is full"          "$(eff 7 12)/$(eff 8 12)" "5/12"
ck "a VM without a floor gets 5 either way"         "$(eff 59 '')/$(eff 1 '')" "5/5"
ck "SHIP_FULL_MIN_SERVICES moves the cut-over"      "$(SHIP_FULL_MIN_SERVICES=2 eff 2 12)" "12"
ck "junk input degrades to the default"             "$(eff x y)"    "5"

# wired in: the dispatch script calls it, before the services launch, and never for a build-only ship
D="$REPO_ROOT/1_cicd/src/scripts/cloud-ship-ci-builder-dispatch.sh"
ln_guard="$(grep -n 'ship_disk_headroom_guard "\$VM"' "$D" | head -1 | cut -d: -f1)"
ln_launch="$(grep -n '^SHIP_CMDS=\$(mktemp)' "$D" | head -1 | cut -d: -f1)"
ck "dispatch calls the guard before launching services" "$([ -n "$ln_guard" ] && [ -n "$ln_launch" ] && [ "$ln_guard" -lt "$ln_launch" ] && echo yes || echo no)" "yes"
ck "build-only ship skips the guard" "$(python3 -I - "$D" <<'PY'
import sys
s = open(sys.argv[1]).read()
g = s.index('ship_disk_headroom_guard "$VM"')
c = s.rfind('if [ "$SHIP_VERB" != "ship-build" ]', 0, g)
print("yes" if c != -1 and "\nfi\n" not in s[c:g] else "no")
PY
)" "yes"

echo ""; echo "  passed $pass, failed $fail"
[ "$fail" -eq 0 ] || exit 1
