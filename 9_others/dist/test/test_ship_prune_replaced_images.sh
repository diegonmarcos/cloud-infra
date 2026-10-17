#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_ship_prune_replaced_images.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# After a ship, the images it REPLACED are removed -- and only those.
#
# `docker image prune -f` only reaps untagged layers; every redeploy leaves the previous version
# of each service's image tagged, ~8 GB per full ship on oci-apps (which then hit 100% disk).
# cloud-ship-disk-headroom.sh's remote script removes, for repositories that a container runs
# RIGHT NOW, the tags whose image id no container (running or stopped) references. Never forced.
# Driven against a stub `docker`: no VM, no network.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(_d="$SCRIPT_DIR"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
LIB="$REPO_ROOT/1_cicd/src/scripts/cloud-ship-disk-headroom.sh"
D="$REPO_ROOT/1_cicd/src/scripts/cloud-ship-ci-builder-dispatch.sh"
[ -f "$LIB" ] || { echo "FAIL: $LIB missing"; exit 1; }
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1: expected '$3', got '$2'"; fi; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir "$W/bin"
# Fleet fixture: 3 containers. app (running, newest id), db (running), jobx (STOPPED, on an old app-like image).
cat > "$W/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "ps -aq")  printf 'c-app\nc-db\nc-jobx\n' ;;
  "ps -a")   printf 'ghcr.io/o/app-binaries:latest\nredis:7\nghcr.io/o/jobx-binaries@sha256:aaaa\n' ;;
  "inspect --format") shift 2; for c in "$@"; do case "$c" in
      c-app)  echo sha256:app-new ;; c-db) echo sha256:redis7 ;; c-jobx) echo sha256:jobx-old ;; esac; done ;;
  "image ls")
    for a in "$@"; do case "$a" in reference=*) ref="${a#reference=}" ;; esac; done
    case "$ref" in
      ghcr.io/o/app-binaries)  printf 'ghcr.io/o/app-binaries:latest sha256:app-new\nghcr.io/o/app-binaries:prev sha256:app-old\nghcr.io/o/app-binaries:<none> sha256:dangling\n' ;;
      redis)                   printf 'redis:7 sha256:redis7\nredis:6 sha256:redis6\n' ;;
      ghcr.io/o/jobx-binaries) printf 'ghcr.io/o/jobx-binaries:latest sha256:jobx-old\n' ;;
    esac ;;
  "rmi "*|"rmi ") echo "$2" >> "$STUB_RMI"; [ "$2" = "-f" ] && echo FORCED >> "$STUB_RMI"; exit 0 ;;
  *) echo "UNEXPECTED: $*" >> "$STUB_RMI"; exit 9 ;;
esac
STUB
chmod +x "$W/bin/docker"
export PATH="$W/bin:$PATH" STUB_RMI="$W/rmi"; : > "$STUB_RMI"
log() { :; }; log_error() { :; }

# shellcheck disable=SC1090
. "$LIB"
bash -c "$SHIP_PRUNE_REPLACED_REMOTE" > "$W/out" 2>&1

ck "old tag of a running service is removed"        "$(grep -c '^ghcr.io/o/app-binaries:prev$' "$STUB_RMI")" "1"
ck "old tag of a running db image is removed"       "$(grep -c '^redis:6$' "$STUB_RMI")" "1"
ck "the image a container runs is kept"             "$(grep -c -E '^ghcr.io/o/app-binaries:latest$|^redis:7$' "$STUB_RMI")" "0"
ck "a STOPPED container's image is kept"           "$(grep -c 'jobx' "$STUB_RMI")" "0"
ck "untagged (<none>) entries are left to prune -f" "$(grep -c 'none' "$STUB_RMI")" "0"
ck "exactly the two replaced tags go"               "$(grep -c . "$STUB_RMI")" "2"
ck "rmi is never forced"                            "$(grep -c -E 'FORCED|^-f$' "$STUB_RMI")" "0"
ck "no unexpected docker call"                      "$(grep -c UNEXPECTED "$STUB_RMI")" "0"
ck "it reports what it removed"                     "$(grep -c '^removed ' "$W/out")" "2"
ck "no 'prune -a' / 'system prune' anywhere in the lib" "$(grep -v '^\s*#' "$LIB" | grep -c -E 'prune -a|system prune|rmi -f|--force')" "0"

# wired in: the dispatch script prunes after the services ran, not for a build-only ship, and
# reads the per-VM floor from build-gha.json
ln_run="$(grep -n 'ship_prune_replaced_images "\$VM"' "$D" | head -1 | cut -d: -f1)"
ln_launch="$(grep -n '^SHIP_CMDS=\$(mktemp)' "$D" | head -1 | cut -d: -f1)"
ck "prune runs after the services were launched"    "$([ -n "$ln_run" ] && [ -n "$ln_launch" ] && [ "$ln_run" -gt "$ln_launch" ] && echo yes || echo no)" "yes"
ck "build-only ship skips the prune"                "$(grep -B1 'ship_prune_replaced_images "\$VM"' "$D" | grep -c 'ship-build')" "1"
ck "per-VM floor comes from build-gha (.vms[vm].min_free_gb)" "$(grep -c 'jq .*min_free_gb' "$D")" "1"
ck "config.json declares >= 12 GB for oci-apps"     "$(python3 -c "
import json;c=json.load(open('$REPO_ROOT/config.json'))
v=[x for x in c['vms'].values() if x.get('ssh_alias')=='oci-apps'][0]
print('yes' if v['gha'].get('min_free_gb',0)>=12 else 'no')")" "yes"

echo ""; echo "  passed $pass, failed $fail"
[ "$fail" -eq 0 ] || exit 1
