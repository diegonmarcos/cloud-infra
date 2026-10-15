#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloud-ship-container-drain-waiter.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Agent drain — runs ON THE DEPLOY VM, never in CI. step_compose (compose_run, in
# cloud-ship-container-step-deploy-drain.sh) stages it in $DEPLOY_PATH/.drain/ beside probe.sh
# (the service's declared deploy.drain.probe) and cmd.sh (the compose payload that recreates).
#
# Why it exists: the compose payload's `down` + `rm -f` SIGKILLs whatever runs inside the
# container. For an agent container that is every agent mid-task — six at once on 2026-10-01
# 11:32Z, from an ordinary ship of a bootstrap change. So for a service that declares
# deploy.drain, cmd.sh runs only once probe.sh reports no live agent in any declared container,
# or once max_wait has passed (then it says loudly whom it is killing).
#
# Why on the VM and not in the CI job: deploy jobs hold the fleet-wide ship-wg-runner
# concurrency slot and die at 90 minutes, and agents run for hours. Waiting in CI would stall
# every other deploy in the fleet and still time out. `launch` detaches this script, so the CI
# job ends while the wait goes on here.
#
# Usage: waiter.sh <check|run|launch> <max_wait_s> <poll_s> <exec_user> <container>...
#   check   print live agents (empty = drained), touch nothing.
#   run     wait for drain, then run cmd.sh; exit with its rc.
#   launch  `run`, detached, appending to waiter.log; prints the waiter's pid.
# The newest `run` wins: each writes its pid to owner, and an older waiter that sees another
# pid there exits without recreating — cmd.sh is the newest payload by then anyway.
set -u
D=$(cd "$(dirname "$0")" && pwd)
MODE=$1 MAX=$2 POLL=$3 XUSER=$4
shift 4
CONTAINERS="$*"
ts() { date -u +%FT%TZ; }

# An empty probe would report "no agents" and recreate over all of them. Refuse instead.
[ -s "$D/probe.sh" ] && [ -s "$D/cmd.sh" ] || { echo "[drain] probe.sh or cmd.sh missing/empty in $D — refusing" >&2; exit 2; }

probe() { # probe <live.sh args...> -> one line per live agent, across every running declared container
  for c in $CONTAINERS; do
    [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ] || continue
    docker exec -i -u "$XUSER" "$c" sh -s -- "$@" < "$D/probe.sh" \
      || echo "container=$c probe failed rc=$? (counted as live, never as drained)"
  done
}

case "$MODE" in
  check)  probe list; exit 0 ;;
  launch) setsid nohup bash "$0" run "$MAX" "$POLL" "$XUSER" $CONTAINERS >> "$D/waiter.log" 2>&1 < /dev/null &
          echo "$!"; exit 0 ;;
  run)    ;;
  *)      echo "[drain] unknown mode: $MODE" >&2; exit 64 ;;
esac

echo "$$" > "$D/owner"
owned() {
  [ "$(cat "$D/owner" 2>/dev/null)" = "$$" ] && return 0
  echo "[drain] $(ts) pid $$ superseded by a newer ship (pid $(cat "$D/owner" 2>/dev/null)) — exiting without recreating"
  exit 0
}
DEADLINE=$(( $(date +%s) + MAX ))
echo "[drain] $(ts) pid $$: recreate of $CONTAINERS waits until no agent is live (max ${MAX}s)"
while :; do
  owned
  # hold: fire.sh refuses new agents while this lease is fresh; renewed every poll, so a dead
  # waiter reopens admission on its own within one lease.
  LIVE=$(probe hold $(( $(date +%s) + 2 * POLL + 60 )))
  [ -n "$LIVE" ] || break
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "[drain] $(ts) MAX WAIT ${MAX}s REACHED — recreating OVER these live agents:"
    echo "$LIVE" | sed 's/^/[drain]   /'
    break
  fi
  echo "[drain] $(ts) WAITING — $(echo "$LIVE" | grep -c .) live agent(s) in $CONTAINERS:"
  echo "$LIVE" | sed 's/^/[drain]   /'
  sleep "$POLL"
done

exec 9> "$D/lock"
flock 9
owned
probe hold $(( $(date +%s) + 900 )) > /dev/null # admission stays shut through pull/down/up
echo "[drain] $(ts) drained — running the recreate"
bash "$D/cmd.sh"
RC=$?
probe release > /dev/null 2>&1 # into the NEW container; if it never came up the hold lapses alone
echo "[drain] $(ts) recreate rc=$RC"
exit "$RC"
