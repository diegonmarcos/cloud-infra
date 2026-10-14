#!/usr/bin/env bash
# test_compose_evict_socket_address.sh — socket eviction compares the ADDRESS.
#
# THE DEFECT UNDER TEST (backlog #986 follow-up)
#
# For a network_mode:host service the deploy evicts any container listening on
# the service's .ports.app. It used to match the port number only. On
# 2026-10-10 21:51 c3-infra-api (binds 10.0.0.6:8081) was deployed while
# matomo-hybrid ran its internal matomo-nginx on 127.0.0.1:8081. Those two
# sockets coexist on Linux, yet the deploy logged
#   evicting matomo-hybrid — it holds :8081, which this service binds
# and removed it. Matomo stayed absent for three days.
#
# Two listeners on one port collide only when their addresses overlap: the
# same address, or either side a wildcard (0.0.0.0, ::, *). This drives the
# exact VM-side text the deploy payload carries (evict_socket_pre/_run from
# cloud-ship-container-step-deploy-compose.sh) against stubbed `sudo ss`,
# /proc/<pid>/cgroup and `docker`, under `sh -e` (the custom-compose path) and
# bash (the standard path). No daemon, no VM.
#
# Cases (the three the ticket names, plus the guards around them):
#   1. loopback vs mesh           127.0.0.1 holder, we bind 10.0.0.6  -> kept
#   2. wildcard overlap           0.0.0.0 holder,  we bind 10.0.0.6  -> evicted
#      wildcard on OUR side       we bind 0.0.0.0, holder 127.0.0.1  -> evicted
#      IPv6 wildcard holder       [::] holder,     we bind 10.0.0.6  -> evicted
#      unknown own bind           we are not running -> treated as 0.0.0.0
#   3. same address               10.0.0.6 holder, we bind 10.0.0.6  -> evicted
#   4. bridged holder (docker-proxy owns the socket, seen via docker ps):
#      10.0.0.6:8080-> vs our 127.0.0.1 -> kept; vs our 0.0.0.0 -> evicted
#   5. never evicts a container we declare ourselves
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(_d="$SCRIPT_DIR"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
STEP="$REPO_ROOT/1_cicd/src/scripts/cloud-ship-container-step-deploy-compose.sh"
[ -f "$STEP" ] || { echo "FAIL: $STEP missing"; exit 1; }

pass=0; fail=0
ck() {
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"
  else fail=$((fail+1)); echo "  FAIL $1: expected '$3', got '$2'"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FIX="$WORK/fix"; mkdir -p "$WORK/bin" "$FIX/proc" "$FIX/names"

# ── Stubs ────────────────────────────────────────────────────────────────
# sudo: `ss` prints the fixture for the current phase (before/after `down`);
#       anything else runs with /proc/... rewritten into the fixture tree.
cat > "$WORK/bin/sudo" <<STUB
#!/bin/sh
if [ "\$1" = ss ]; then
  phase=\$(cat "$FIX/phase")
  [ -f "$FIX/ss.\$phase" ] && cat "$FIX/ss.\$phase"
  exit 0
fi
cmd=\$1; shift
set -- \$(for a in "\$@"; do case "\$a" in /proc/*) printf '%s\n' "$FIX\$a" ;; *) printf '%s\n' "\$a" ;; esac; done)
exec "\$cmd" "\$@"
STUB
# docker: inspect --format {{.Name}} <cid>, rm -f <id>, ps --format ...
cat > "$WORK/bin/docker" <<STUB
#!/bin/sh
case "\$1" in
  inspect) eval "cid=\\\${\$#}"; [ -f "$FIX/names/\$cid" ] && printf '/%s\n' "\$(cat "$FIX/names/\$cid")" ;;
  rm)      shift; while [ "\$1" = "-f" ]; do shift; done; echo "\$1" >> "$FIX/removed" ;;
  ps)      [ -f "$FIX/ps" ] && cat "$FIX/ps" ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/sudo" "$WORK/bin/docker"
PATH="$WORK/bin:$PATH"; export PATH

# Pull ONLY the generator functions out of the step, so the test runs the text
# the payload really carries without sourcing the whole engine step.
eval "$(sed -n '/^evict_socket_lib() {/,$p' "$STEP")"
command -v evict_socket_pre >/dev/null || { echo "FAIL: evict_socket_pre not defined in $STEP"; exit 1; }

hex() { printf '%064d' "$1" | tr '0123456789' 'abcdef0123'; }   # fake 64-hex container id

# container <pid> <name>: a process inside a named container
container() {
  _cid="$(hex "$1")"
  mkdir -p "$FIX/proc/$1"
  printf '0::/system.slice/docker-%s.scope\n' "$_cid" > "$FIX/proc/$1/cgroup"
  printf '%s' "$2" > "$FIX/names/$_cid"
}
# listen <phase> <addr:port> <pid>: one ss -lntpH line
listen() { printf 'LISTEN 0 511 %s 0.0.0.0:* users:(("nginx",pid=%s,fd=6))\n' "$2" "$3" >> "$FIX/ss.$1"; }

reset() { rm -rf "$FIX"; mkdir -p "$FIX/proc" "$FIX/names"; echo before > "$FIX/phase"; }

# run <shell> <port> <our declared names>: PRE before `down`, RUN after it.
# Prints the sorted container names the stub was asked to remove.
run() {
  { evict_socket_pre "$2" "$3"
    printf 'echo after > "%s/phase"\n' "$FIX"       # `docker compose down`
    evict_socket_run "$2"; } > "$WORK/payload.sh"
  case "$1" in
    sh)   sh -e "$WORK/payload.sh" > "$WORK/out" 2>&1 || echo "PAYLOAD-ABORTED" >> "$FIX/removed" ;;
    bash) bash "$WORK/payload.sh" > "$WORK/out" 2>&1 || echo "PAYLOAD-ABORTED" >> "$FIX/removed" ;;
  esac
  sort -u "$FIX/removed" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'
}

ID_MATOMO="$(hex 200)"; ID_OLD="$(hex 300)"

for SH in sh bash; do
  echo "== under $SH =="

  # 1. loopback vs mesh — the matomo incident. No eviction.
  reset; container 100 c3-infra-api; container 200 matomo-hybrid
  listen before 10.0.0.6:8081 100; listen before 127.0.0.1:8081 200
  listen after  127.0.0.1:8081 200
  ck "[$SH] loopback 127.0.0.1 holder vs our 10.0.0.6 bind: kept" "$(run $SH 8081 'c3-infra-api ')" ""
  grep -q 'keeping matomo-hybrid' "$WORK/out" \
    && ck "[$SH] the keep decision is logged" ok ok \
    || ck "[$SH] the keep decision is logged" "$(cat "$WORK/out")" "a 'keeping matomo-hybrid' line"

  # 2a. wildcard holder overlaps our specific address. Evict.
  reset; container 100 c3-infra-api; container 200 matomo-hybrid
  listen before 10.0.0.6:8080 100; listen before 0.0.0.0:8080 200
  listen after  0.0.0.0:8080 200
  ck "[$SH] wildcard 0.0.0.0 holder vs our 10.0.0.6: evicted" "$(run $SH 8080 'c3-infra-api ')" "$ID_MATOMO"

  # 2b. OUR side is the wildcard. Evict.
  reset; container 100 matomo-hybrid; container 300 old-svc
  listen before 0.0.0.0:8080 100; listen before 127.0.0.1:8080 300
  listen after  127.0.0.1:8080 300
  ck "[$SH] our 0.0.0.0 bind vs 127.0.0.1 holder: evicted" "$(run $SH 8080 'matomo-hybrid ')" "$ID_OLD"

  # 2c. IPv6 wildcard holder. Evict.
  reset; container 100 c3-infra-api; container 300 old-svc
  listen before 10.0.0.6:8081 100; listen before '[::]:8081' 300
  listen after  '[::]:8081' 300
  ck "[$SH] [::] holder vs our 10.0.0.6: evicted" "$(run $SH 8081 'c3-infra-api ')" "$ID_OLD"

  # 2d. We are not running (first deploy / absent / rename): unknown = 0.0.0.0,
  #     the old port-only behaviour, so a stale predecessor still goes.
  reset; container 300 c3-services-mcp
  listen before 10.0.0.6:3101 300; listen after 10.0.0.6:3101 300
  ck "[$SH] own bind unknown (not running) -> treated as wildcard: evicted" "$(run $SH 3101 'cloud-services-mcp ')" "$ID_OLD"

  # 3. same address. Evict.
  reset; container 100 cloud-infra-mcp; container 300 c3-infra-mcp
  listen before 10.0.0.6:3100 100; listen before 10.0.0.6:3100 300
  listen after  10.0.0.6:3100 300
  ck "[$SH] same address 10.0.0.6 vs 10.0.0.6: evicted" "$(run $SH 3100 'cloud-infra-mcp ')" "$ID_OLD"

  # 4. bridged holder: docker-proxy owns the socket (no container cgroup), so
  #    only `docker ps` names it.
  reset; container 100 matomo-hybrid
  mkdir -p "$FIX/proc/900"; printf '0::/system.slice/docker.service\n' > "$FIX/proc/900/cgroup"
  listen before 127.0.0.1:8080 100; listen before 10.0.0.6:8080 900
  listen after 10.0.0.6:8080 900
  printf '%s\n' "wireguard-mesh 80/tcp, 10.0.0.6:8080->8080/tcp" "filebrowser_app 10.0.0.6:3015->8080/tcp" > "$FIX/ps"
  ck "[$SH] bridged 10.0.0.6:8080 holder vs our 127.0.0.1: kept" "$(run $SH 8080 'matomo-hybrid ')" ""
  reset; container 100 matomo-hybrid
  listen before 0.0.0.0:8080 100
  printf '%s\n' "wireguard-mesh 80/tcp, 10.0.0.6:8080->8080/tcp" "filebrowser_app 10.0.0.6:3015->8080/tcp" > "$FIX/ps"
  ck "[$SH] bridged 10.0.0.6:8080 holder vs our 0.0.0.0: evicted (and only it)" "$(run $SH 8080 'matomo-hybrid ')" "wireguard-mesh"

  # 5. never ourselves, even on a wildcard.
  reset; container 100 matomo-hybrid; container 101 matomo-hybrid
  listen before 0.0.0.0:8080 100; listen before '[::]:8080' 101
  ck "[$SH] never evicts a container we declare" "$(run $SH 8080 'matomo-hybrid ')" ""

  # Nothing listening at all must not abort a `set -e` payload.
  reset
  ck "[$SH] empty port: no eviction, payload completes" "$(run $SH 8080 'x ')" ""
done

echo "== wiring in the step =="
# The capture must run BEFORE `down` (afterwards our own listener is gone and
# every bind reads as unknown) and the eviction after it, on both paths.
std="$(grep -c 'EVICT_SOCKET_PRE:+$EVICT_SOCKET_PRE; }docker compose $CF \\$ENV_FILE_FLAG down' "$STEP")"
ck "standard path: capture precedes down (both PAYLOAD variants)" "$std" "2"
custom="$(grep -n -e 'printf .%s\\n. "$EVICT_SOCKET_PRE"' -e "echo 'docker compose \$COMPOSE_FILE_FLAG \$ENV_FILE_FLAG down" "$STEP" | cut -d: -f1 | tr '\n' ' ')"
set -- $custom
[ "$#" -eq 2 ] && [ "$1" -lt "$2" ] && ck "custom path: capture echoed before down" ok ok \
  || ck "custom path: capture echoed before down" "$custom" "two line numbers, capture first"
old="$(grep -c 'it holds :$_appport' "$STEP")"
ck "the port-only eviction line is gone" "$old" "0"

echo
if [ "$fail" -eq 0 ]; then echo "PASS ($pass assertions)"; exit 0; fi
echo "FAIL ($fail of $((pass+fail)))"
exit 1
