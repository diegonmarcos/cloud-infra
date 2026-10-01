#!/usr/bin/env bash
# A ship must not recreate an agent container under live agents.
#
# 2026-10-01: cloud-agi-claude was recreated by three ordinary ships; the 11:32Z one SIGKILLed
# six agents mid-task. The fix is three pieces, and each is driven here for real:
#   live.sh (cloud-u-containers/_dispatch)  the one reader of "which agents are live"
#   fire.sh (same dir)                      registers each agent for its life, refuses new ones
#                                           while a drain holds admission
#   drain-waiter + compose_run (engine)     a live agent defers the recreate to the VM; none
#                                           live lets it run now
# docker and ssh are stubs on PATH; processes are planted in a fake /proc (DISPATCH_PROC), so
# nothing here depends on the agents actually running on the box that runs the test.
#
# Overrides exist only for the mutation runs: SOL (cloud-u-containers checkout), SCRIPTS
# (engine script dir).
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SOL=${SOL:-$ROOT/a_solutions}
SCRIPTS=${SCRIPTS:-$ROOT/1_cicd/src/scripts}
LIVE_SH=$SOL/_dispatch/live.sh
FIRE_SH=$SOL/_dispatch/fire.sh
WAITER=$SCRIPTS/cloud-ship-container-drain-waiter.sh
DRAIN_STEP=$SCRIPTS/cloud-ship-container-step-deploy-drain.sh
ENGINE=$SCRIPTS/cloud-ship-container-engine.sh
for f in "$LIVE_SH" "$FIRE_SH" "$WAITER" "$DRAIN_STEP" "$ENGINE"; do
  [ -f "$f" ] || { echo "FAIL: $f missing"; exit 1; }
done

T=$(mktemp -d)
cleanup() { pkill -f "$T/" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT INT TERM
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; \
       else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }
waitfor() { local i=0; while [ $i -lt "$2" ]; do eval "$1" && return 0; sleep 1; i=$((i+1)); done; return 1; }

export DISPATCH_ROOT=$T/root DISPATCH_PROC=$T/proc
REG=$T/root/_dispatch/logs/live
mkdir -p "$REG" "$T/proc" "$T/bin"
plant() { mkdir -p "$T/proc/$1"; printf '%s\0' $2 > "$T/proc/$1/cmdline"; }   # plant <pid> "<argv>"
register() { echo "slot=$1 engine=claude repo=demo model=opus pid=$2 start=x" > "$REG/$1"; }
reset() { rm -rf "$T/proc"/* "$REG"/* "$REG/.draining"; }

echo "── live.sh: who is live"
ck "nothing registered, nothing running → drained (empty)" "$(sh "$LIVE_SH" list)" ""
plant 101 "sh /x/_dispatch/fire.sh claude 900 demo opus"; register 900 101
ck "registered agent whose pid is its fire.sh → listed WITH its registry fields" "$(sh "$LIVE_SH" list | grep -c '^slot=900 engine=claude repo=demo model=opus pid=101')" "1"
register 901 102
ck "registered agent whose pid is gone (container was killed) → not live" "$(sh "$LIVE_SH" list | grep -c 'slot=901')" "0"
plant 103 "python3 server.py"; register 902 103
ck "registered agent whose pid was recycled → not live" "$(sh "$LIVE_SH" list | grep -c 'slot=902')" "0"
plant 104 "sh /home/appuser/git/_dispatch/../cloud-u-containers/_dispatch/run.sh claude 903 /p.md /l opus"
ck "run.sh with no registry entry (old fire.sh, hand-run) → listed as unregistered" \
   "$(sh "$LIVE_SH" list | grep -c '^slot=903 .*unregistered')" "1"
plant 105 "sh /x/_dispatch/run.sh claude 900 /p.md /l opus"
ck "a registered agent's own run.sh is not counted twice" "$(sh "$LIVE_SH" list | grep -c 'slot=900')" "1"
sh "$LIVE_SH" hold 4102444800 > /dev/null
ck "hold writes the admission marker" "$(cat "$REG/.draining" 2>/dev/null)" "4102444800"
sh "$LIVE_SH" release
ck "release removes it" "$([ -e "$REG/.draining" ] && echo present || echo gone)" "gone"
reset

echo "── fire.sh: registers for its life, refuses while draining"
D=$T/root/_dispatch
cp "$FIRE_SH" "$D/fire.sh"
echo "brief" > "$D/dispatch-t1.md"; echo "brief" > "$D/dispatch-t2.md"; echo "brief" > "$D/dispatch-t3.md"
echo 'echo "$*" >> "'"$T"'/prep.calls"' > "$D/prep.sh"
# run.sh stub: what the ship would see WHILE this agent runs (real /proc — fire.sh is real).
cat > "$D/run.sh" <<EOF
DISPATCH_PROC=/proc sh "$LIVE_SH" list > "$T/during.\$2"
EOF
sh "$D/fire.sh" claude t1 demo opus; RC=$?
ck "a normal fire runs (rc 0, prep called)" "$RC $(grep -c ' t1 ' "$T/prep.calls" 2>/dev/null)" "0 1"
ck "while it runs, live.sh lists it as REGISTERED (not merely as a process)" \
   "$(grep '^slot=t1 ' "$T/during.t1" | grep -vc unregistered)" "1"
ck "after it exits, its registry entry is gone" "$([ -e "$REG/t1" ] && echo left || echo gone)" "gone"
echo $(( $(date +%s) + 3600 )) > "$REG/.draining"
sh "$D/fire.sh" claude t2 demo opus; RC=$?
ck "a fire during a drain hold is refused with rc 75" "$RC" "75"
ck "...before any workspace is made (prep never called)" "$(grep -c ' t2 ' "$T/prep.calls")" "0"
ck "...and says why in its marker" "$(grep -c 'FIRE ABORT: draining' "$D/logs/dispatch-t2.marker")" "1"
ck "...and leaves no registry entry" "$([ -e "$REG/t2" ] && echo left || echo gone)" "gone"
echo $(( $(date +%s) - 1 )) > "$REG/.draining"
sh "$D/fire.sh" claude t3 demo opus; RC=$?
ck "an expired hold (dead waiter) does not block fires" "$RC $(grep -c ' t3 ' "$T/prep.calls")" "0 1"
reset

echo "── drain waiter (runs on the VM): a live agent blocks the recreate"
cat > "$T/bin/docker" <<'EOF'
#!/bin/sh
case "$1" in
  inspect) echo true ;;
  exec) shift
        while [ $# -gt 0 ]; do case "$1" in -i) shift ;; -u) shift 2 ;; *) break ;; esac; done
        shift   # container
        [ -n "${STUB_EXEC_FAIL:-}" ] && exit 125
        exec "$@" ;;
esac
EOF
chmod +x "$T/bin/docker"
export PATH="$T/bin:$PATH"
V=$T/vm/.drain; mkdir -p "$V"
cp "$WAITER" "$V/waiter.sh"; cp "$LIVE_SH" "$V/probe.sh"
echo "echo recreated >> '$T/recreated'" > "$V/cmd.sh"
W() { bash "$V/waiter.sh" "$@"; }
recreated() { grep -c recreated "$T/recreated" 2>/dev/null || echo 0; }

plant 201 "sh /x/_dispatch/fire.sh claude 950 demo opus"; register 950 201
ck "check names the live agent" "$(W check 3600 1 appuser c1 | grep -c '^slot=950 ')" "1"
W run 3600 1 appuser c1 > "$T/w1.log" 2>&1 &
WP=$!
sleep 3
ck "SIMULATED RUNNING AGENT: no recreate while it lives" "$(recreated)" "0"
ck "...the waiter says it is waiting, and for whom" "$(grep -q WAITING "$T/w1.log" && grep -q 'slot=950' "$T/w1.log" && echo yes)" "yes"
ck "...and holds admission shut (fire.sh would refuse)" "$([ "$(cat "$REG/.draining" 2>/dev/null)" -gt "$(date +%s)" ] 2>/dev/null && echo held || echo open)" "held"
rm -rf "$T/proc/201"            # the agent finishes
waitfor '[ "$(recreated)" = 1 ]' 10
wait "$WP"; RC=$?
ck "agent gone → the recreate runs exactly once, rc 0" "$(recreated) $RC" "1 0"
ck "...and admission reopens after it" "$([ -e "$REG/.draining" ] && echo held || echo open)" "open"
reset; rm -f "$T/recreated"

ck "nothing live → check is empty" "$(W check 3600 1 appuser c1)" ""
W run 3600 1 appuser c1 > /dev/null 2>&1; RC=$?
ck "nothing live → run recreates immediately" "$(recreated) $RC" "1 0"
rm -f "$T/recreated"

plant 202 "sh /x/_dispatch/run.sh claude 951 /p.md /l opus"
W run 0 1 appuser c1 > "$T/w2.log" 2>&1
ck "max wait reached → recreates, and names whom it killed" "$(recreated) $(grep -c 'MAX WAIT' "$T/w2.log") $(grep -c 'slot=951' "$T/w2.log")" "1 1 1"
reset; rm -f "$T/recreated"

ck "a probe that fails counts as live, never as drained" "$(STUB_EXEC_FAIL=1 W check 3600 1 appuser c1 | grep -c 'probe failed')" "1"

plant 203 "sh /x/_dispatch/fire.sh claude 952 demo opus"; register 952 203
W run 3600 1 appuser c1 > "$T/wa.log" 2>&1 & WA=$!
sleep 2
W run 3600 1 appuser c1 > "$T/wb.log" 2>&1 & WB=$!
sleep 3
rm -rf "$T/proc/203"
wait "$WA"; wait "$WB"
ck "two ships waiting: the older exits superseded, the recreate runs ONCE" \
   "$(grep -c superseded "$T/wa.log") $(recreated)" "1 1"
reset; rm -f "$T/recreated"

: > "$V/probe.sh"
W run 3600 1 appuser c1 > /dev/null 2>&1; RC=$?
ck "an empty probe refuses (rc 2) rather than reading as 'no agents'" "$RC $(recreated)" "2 0"
cp "$LIVE_SH" "$V/probe.sh"

echo "── compose_run (CI side): defer on live agents, run on none"
# ssh stub: the remote command is the last argument; run it locally, stdin passed through.
cat > "$T/bin/ssh" <<'EOF'
#!/bin/sh
for a; do last=$a; done
exec bash -c "$last"
EOF
chmod +x "$T/bin/ssh"
SVC=$T/svc; mkdir -p "$SVC/../_dispatch"; cp "$LIVE_SH" "$SVC/../_dispatch/live.sh"
drain_json='{"deploy":{"drain":{"probe":"../_dispatch/live.sh","max_wait_seconds":3600,"poll_seconds":1,"exec_user":"appuser"}}}'
cr() { # cr <build.json> → runs compose_run with a payload that marks $T/recreated; prints rc
  (
    CONFIG=$SVC/build.json; SERVICE_DIR=$SVC; STEPS_DIR=$SCRIPTS
    DEPLOY_HOST=vm; DEPLOY_PATH=$T/vm; COMPOSE_POST_HOOK=""; SSH_OPTS=""
    # A sync run that waits on an agent must fail here, not hang the suite (mutation M7).
    SSH_DETACH_MAX=15
    printf '%s' "$1" > "$CONFIG"
    log() { echo "LOG $1"; }; log_warn() { echo "WARN $1"; }; log_error() { echo "ERR $1"; }
    get_config() { jq -r ".$1 // empty" "$CONFIG"; }
    eval "$(sed -n '/^ssh_with_retry() {/,/^}/p; /^ssh_run_detached() {/,/^}/p' "$ENGINE")"
    . "$DRAIN_STEP"
    compose_run "echo recreated >> '$T/recreated'" compose-test "c1"
    echo "rc=$?"
  ) > "$T/cr.log" 2>&1
  tail -1 "$T/cr.log"
}
plant 301 "sh /x/_dispatch/fire.sh claude 960 demo opus"; register 960 301
RC=$(cr "$drain_json")
sleep 2
ck "LIVE AGENT: compose_run returns 0 WITHOUT recreating" "$RC $(recreated)" "rc=0 0"
ck "...logs DEFERRED and names the agent" "$(grep -c 'DEFERRED' "$T/cr.log") $(grep -c 'live: slot=960' "$T/cr.log")" "1 1"
ck "...and leaves a waiter on the VM, waiting and holding admission" "$(grep -q 'WAITING' "$T/vm/.drain/waiter.log" && [ -e "$REG/.draining" ] && echo yes)" "yes"
rm -rf "$T/proc/301"
waitfor '[ "$(recreated)" = 1 ]' 10
ck "...which recreates once the agent is gone" "$(recreated)" "1"
reset; rm -f "$T/recreated"

RC=$(cr "$drain_json")
ck "NO LIVE AGENT: compose_run recreates now, in the job" "$RC $(recreated)" "rc=0 1"
rm -f "$T/recreated"

plant 302 "sh /x/_dispatch/fire.sh claude 961 demo opus"; register 961 302
RC=$(cr '{"deploy":{}}')
ck "no deploy.drain declared → unchanged behaviour (recreates directly)" "$RC $(recreated)" "rc=0 1"
rm -f "$T/recreated"
RC=$(SHIP_DRAIN_FORCE=1 cr "$drain_json")
ck "SHIP_DRAIN_FORCE → recreates over the live agent, and says so" "$RC $(recreated) $(grep -c 'DRAIN OVERRIDDEN' "$T/cr.log")" "rc=0 1 1"
rm -f "$T/recreated"
RC=$(cr '{"deploy":{"drain":{"probe":"../_dispatch/live.sh","max_wait_seconds":"x","poll_seconds":1,"exec_user":"appuser"}}}')
ck "a malformed drain declaration fails the step, recreates nothing" "$RC $(recreated)" "rc=1 0"
reset

echo "── wiring: step_compose reaches the VM only through compose_run"
COMPOSE=$SCRIPTS/cloud-ship-container-step-deploy-compose.sh
ck "no compose payload is sent with a bare ssh_run_detached" \
   "$(grep -A1 '^ *ssh_run_detached' "$COMPOSE" | grep -cE '\$PAYLOAD|sh \$SCRIPT_NAME')" "0"
ck "both compose paths call compose_run" "$(grep -c '^ *compose_run ' "$COMPOSE")" "2"
ck "the engine sources the drain step" "$(grep -c 'cloud-ship-container-step-deploy-drain.sh' "$ENGINE")" "1"

echo
echo "drain: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
