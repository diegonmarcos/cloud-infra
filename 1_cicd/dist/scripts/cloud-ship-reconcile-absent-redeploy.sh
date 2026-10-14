#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_cicd/src/scripts/cloud-ship-reconcile-absent-redeploy.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ cloud-ship-reconcile-absent-redeploy.sh — bring back ONE absent service   ║
# ╚══════════════════════════════════════════════════════════════════════════╝
#
# WHY THIS EXISTS (backlog #986 follow-up)
#
# cloud-ship-reconcile.sh reports `absent` (declared, no container at all) and
# nothing ever acts on it. matomo-hybrid was removed on 2026-10-10 21:51 by
# another service's deploy (a port-only socket eviction), every later Ship
# skipped matomo as "unchanged", and the reconcile printed
#   ABSENT — declared but not running
# every four hours for three days while nothing recreated it. Its compose
# file, its image and its secrets were all still on the VM; one
# `docker compose up -d` was the whole repair.
#
# WHAT IT DOES, AND THE BOUNDS ON IT
#
# Reads the reconcile's findings and, for `absent` findings ONLY, re-runs
# `docker compose up -d` for that service's already-deployed project on its VM:
#
#   * AT MOST ONE service per run. The candidates are checked in order and the
#     first one that passes every check below is brought up; the rest wait for
#     the next reconcile. Convergence by repetition, like the re-ship.
#   * NEVER during a cgc-db restore. Checked twice, both fail-safe: GitHub says
#     no cgc-db-restore.yml run is in progress (an API error counts as "maybe"),
#     and the VM shows no restore script running (the Dagu path runs it on the
#     box, outside GitHub). The restore stops and swaps the MCP containers; a
#     reconcile recreating one mid-swap would serve a half-staged volume.
#   * NOT a deploy. `up -d --no-recreate --no-build --pull never` on the compose
#     file the last Ship left on the VM: no rsync, no pull, no `down`, no
#     eviction, and containers that do exist are not touched. A service that
#     needs new code still needs a Ship; this only restores what was there.
#   * Skipped, and alerted, when it cannot be safe:
#       - listed in ship-reconcile.json absent_redeploy.exclude (absent by
#         design: retired, on-demand, or run outside compose);
#       - no engine-deployed project on the VM (no compose file or no
#         .deploy-manifest): that is a first deploy, which is a Ship's job;
#       - an image the compose names is not in the VM's local cache;
#       - something else holds the service's .ports.app. Starting into a port
#         clash is how matomo and wireguard-mesh kept evicting each other; the
#         alert names the holder so a human re-allocates one of them.
#
# CONTRACT
#
#   argv   : --apply | --dry-run (default --dry-run: says what it would do)
#   stdin  : cloud-ship-reconcile.sh findings — <vm> <dir> <class> <detail>
#   stdout : one line — `redeployed <dir>`, `would-redeploy <dir>`, `none`,
#            `refused <reason>` or `failed <dir>`
#   stderr : every candidate and why it was taken or skipped
#   exit 0 : nothing to do, everything skipped, dry-run, refused, or the
#            redeploy came up
#   exit 1 : a redeploy was attempted and its containers are not running
#
# TESTING SEAMS (all default to the real thing; the tester replaces them)
#   ABSENT_REMOTE_CMD        <vm>            stdin = bash script run on the VM
#   ABSENT_RESTORE_RUNS_CMD                  prints in-progress restore runs;
#                                            non-zero exit = cannot tell
#   ABSENT_NOTIFY_CMD        <title> <body>  best-effort alert
# 9_others/test/test_ship_reconcile_absent_redeploy.sh drives all three.
#
# Never prints a secret: nothing here reads .secrets; `docker compose` is only
# asked for image names (`config --images`) and container states.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${CLOUD_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
SOLUTIONS_DIR="${SOLUTIONS_DIR:-$REPO_ROOT/a_solutions}"
CONFIG="${RESHIP_CONFIG:-$REPO_ROOT/9_others/ship-reconcile.json}"

note() { printf '%s\n' "$*" >&2; }

MODE="dry-run"
case "${1:-}" in
  --apply) MODE="apply" ;;
  --dry-run|"") MODE="dry-run" ;;
  *) note "usage: $0 [--apply|--dry-run] < findings.tsv"; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { note "::error::jq is required"; echo "refused jq-missing"; exit 0; }
[ -f "$CONFIG" ] || { note "::error::$CONFIG not found — refusing to act"; echo "refused no-config"; exit 0; }

ENABLED="$(jq -r '.absent_redeploy.enabled // false' "$CONFIG")"
SETTLE="$(jq -r '.absent_redeploy.settle_seconds // 20' "$CONFIG")"
NTFY_VM="$(jq -r '.absent_redeploy.ntfy.vm // empty' "$CONFIG")"
NTFY_BASE="${NTFY_URL:-$(jq -r '.absent_redeploy.ntfy.url // empty' "$CONFIG")}"
NTFY_TOPIC="$(jq -r '.absent_redeploy.ntfy.topic // empty' "$CONFIG")"
case "$SETTLE" in ''|*[!0-9]*) SETTLE=20 ;; esac

if [ "$ENABLED" != "true" ]; then
  note "absent redeploy is disabled (ship-reconcile.json absent_redeploy.enabled) — reporting only"
  echo "none"; exit 0
fi

# ── Seams ────────────────────────────────────────────────────────────────
remote() {   # remote <vm>  (script on stdin)
  if [ -n "${ABSENT_REMOTE_CMD:-}" ]; then $ABSENT_REMOTE_CMD "$1"; return; fi
  ssh -o BatchMode=yes -o ConnectTimeout=15 "$1" 'bash -s'
}

restore_runs() {   # prints the number of in-progress cgc-db restore runs
  if [ -n "${ABSENT_RESTORE_RUNS_CMD:-}" ]; then $ABSENT_RESTORE_RUNS_CMD; return; fi
  [ -n "${GH_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] || return 1
  _n=0
  for _st in in_progress queued; do
    # queued counts too: the restore holds ship-wg-runner like this job, so a
    # queued one starts the moment we finish — not a moment to recreate an
    # MCP container it is about to stop.
    _c="$(curl -fsS -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
           "https://api.github.com/repos/$GITHUB_REPOSITORY/actions/workflows/cgc-db-restore.yml/runs?status=$_st&per_page=1" \
          | jq -r '.total_count')" || return 1
    case "$_c" in ''|*[!0-9]*) return 1 ;; esac
    _n=$((_n + _c))
  done
  echo "$_n"
}

notify() {   # notify <title> <body> — best effort, never fails the run
  if [ -n "${ABSENT_NOTIFY_CMD:-}" ]; then $ABSENT_NOTIFY_CMD "$1" "$2" || true; return 0; fi
  [ -n "$NTFY_VM" ] && [ -n "$NTFY_BASE" ] && [ -n "$NTFY_TOPIC" ] || return 0
  _t="$(printf '%s' "$1" | tr -d "'\n")"
  printf '%s\n' "$2" | ssh -o BatchMode=yes -o ConnectTimeout=15 "$NTFY_VM" \
    "curl -s --max-time 15 -X POST '$NTFY_BASE/$NTFY_TOPIC' -H 'Title: $_t' -H 'Tags: recycle,warning' --data-binary @- >/dev/null" \
    >/dev/null 2>&1 || note "::warning::ntfy alert not delivered (best effort): $_t"
}

alert() {   # alert <title> <body> — annotation + ntfy
  note "::warning::$1 — $2"
  notify "$1" "$2"
}

# ── Candidates: absent findings, one per (vm, service dir), in order ─────
FINDINGS="$(cat)"
CANDS="$(printf '%s\n' "$FINDINGS" | awk -F'\t' '$3=="absent" && $1!="" && $2!="" { k=$1"\t"$2; if (!(k in s)) { s[k]=1; print k } }')"
if [ -z "$CANDS" ]; then
  note "no absent findings — nothing to redeploy"
  echo "none"; exit 0
fi
note "absent services: $(printf '%s\n' "$CANDS" | cut -f2 | paste -sd' ' -)"

# ── Restore guard, GitHub side (the VM side runs in each preflight) ──────
if ! RUNS="$(restore_runs)"; then
  alert "reconcile: absent redeploy skipped" "could not tell whether a cgc-db restore is running (GitHub API unreadable) — not touching any container this run"
  echo "refused restore-unknown"; exit 0
fi
if [ "${RUNS:-0}" -gt 0 ]; then
  note "a cgc-db restore is in progress or queued ($RUNS run(s)) — no absent redeploy this run"
  echo "refused restore-running"; exit 0
fi

# ── Remote scripts ───────────────────────────────────────────────────────
# Parameters travel as %q-quoted assignments at the top of the script, never
# interpolated into the logic.
preflight_script() {   # <remote_path> <port> <container names>
  printf '# absent-redeploy:preflight\n'
  printf 'RP=%q\nPORT=%q\nCNAMES=%q\n' "$1" "$2" "$3"
  cat <<'PRE'
set -u
echo "RESTORE=$(pgrep -f '[c]gc-restore-all|[c]gc-db-restore' 2>/dev/null | wc -l | tr -d ' ')"
if ! cd "$RP" 2>/dev/null; then echo "COMPOSE=none"; exit 0; fi
if [ -f compose/docker-compose.yml ]; then CF=compose/docker-compose.yml
elif [ -f docker-compose.yml ]; then CF=docker-compose.yml
else CF=none; fi
echo "COMPOSE=$CF"
[ -f .deploy-manifest ] && echo "MANIFEST=yes" || echo "MANIFEST=no"
ENVF=""
if [ -f compose/.secrets ]; then ENVF="--env-file compose/.secrets"; elif [ -f .secrets ]; then ENVF="--env-file .secrets"; fi
if [ "$CF" != none ]; then
  # --images prints image names only; the resolved config (with secrets) is never printed.
  if imgs="$(docker compose -f "$CF" --project-directory . $ENVF config --images 2>/dev/null)"; then
    miss=""
    for i in $imgs; do docker image inspect "$i" >/dev/null 2>&1 || miss="$miss $i"; done
    echo "IMAGES_MISSING=${miss# }"
  else
    echo "IMAGES_MISSING=<compose config failed>"
  fi
fi
holders=""
if [ -n "$PORT" ]; then
  for p in $(sudo -n ss -lntpH "sport = :$PORT" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u); do
    cid="$(sudo -n sed -nE 's#.*[-/]([0-9a-f]{64})(\.scope)?$#\1#p' "/proc/$p/cgroup" 2>/dev/null | head -1)"
    if [ -n "$cid" ]; then
      n="$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's#^/##')"
      holders="$holders ${n:-container-$cid}"
    else
      c="$(cat "/proc/$p/comm" 2>/dev/null)"
      [ "$c" = docker-proxy ] || holders="$holders host-process:${c:-pid$p}"
    fi
  done
  for n in $(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | awk -v p=":$PORT->" 'index($0, p) { print $1 }'); do
    holders="$holders $n"
  done
fi
echo "PORT_HOLDERS=$(printf '%s\n' $holders | sort -u | tr '\n' ' ')"
PRE
}

up_script() {   # <remote_path> <compose file> <container names> <settle seconds>
  printf '# absent-redeploy:up\n'
  printf 'RP=%q\nCF=%q\nCNAMES=%q\nSETTLE=%q\n' "$1" "$2" "$3" "$4"
  cat <<'UP'
set -u
cd "$RP" || exit 90
ENVF=""
if [ -f compose/.secrets ]; then ENVF="--env-file compose/.secrets"; elif [ -f .secrets ]; then ENVF="--env-file .secrets"; fi
rc=0
docker compose -f "$CF" --project-directory . $ENVF up -d --no-recreate --no-build --pull never 2>&1 | sed 's/^/  compose: /' || rc=$?
[ "$rc" -eq 0 ] || rc=1
sleep "$SETTLE"
for c in $CNAMES; do
  printf 'STATE %s %s\n' "$c" "$(docker inspect --format '{{.State.Status}}' "$c" 2>/dev/null || echo missing)"
done
echo "UP_RC=$rc"
UP
}

kv() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

# ── Walk the candidates; act on at most one ──────────────────────────────
while IFS=$'\t' read -r VM DIR; do
  [ -n "$VM" ] || continue
  reason="$(jq -r --arg d "$DIR" '.absent_redeploy.exclude[$d] // empty' "$CONFIG")"
  if [ -n "$reason" ]; then
    note "  skip $DIR on $VM — excluded: $reason"
    continue
  fi

  BJ="$SOLUTIONS_DIR/$DIR/build.json"
  if [ ! -f "$BJ" ]; then
    note "  skip $DIR on $VM — $BJ not found"
    continue
  fi
  RP="$(jq -r '.deploy.remote_path // empty' "$BJ")"
  PORT="$(jq -r '.ports.app // empty' "$BJ")"
  case "$PORT" in *[!0-9]*) PORT="" ;; esac
  # Same shapes declared_container_names accepts: containers as an object or an array.
  CNAMES="$(jq -r '[.containers // {} | if type == "array" then .[] else to_entries[].value end
                   | .container_name // empty] | join(" ")' "$BJ")"
  # A declared one_shot container (an init job) is allowed to have exited.
  ONESHOT="$(jq -r '[.containers // {} | if type == "array" then .[] else to_entries[].value end
                    | select(.one_shot == true) | .container_name // empty] | join(" ")' "$BJ")"
  if [ -z "$RP" ] || [ -z "$CNAMES" ]; then
    note "  skip $DIR on $VM — build.json declares no deploy.remote_path or no container_name"
    continue
  fi

  if ! PF="$(preflight_script "$RP" "$PORT" "$CNAMES" | remote "$VM")"; then
    note "  skip $DIR on $VM — preflight did not answer"
    continue
  fi

  if [ "$(kv "$PF" RESTORE)" != "0" ]; then
    note "a cgc-db restore is running on $VM — no absent redeploy this run"
    echo "refused restore-running"; exit 0
  fi
  CF="$(kv "$PF" COMPOSE)"
  if [ -z "$CF" ] || [ "$CF" = none ] || [ "$(kv "$PF" MANIFEST)" != yes ]; then
    note "  skip $DIR on $VM — no engine-deployed project at $RP (first deploy is a Ship's job)"
    continue
  fi
  MISSING="$(kv "$PF" IMAGES_MISSING)"
  if [ -n "$MISSING" ]; then
    alert "reconcile: $DIR absent, not redeployed" "$DIR on $VM is absent and its image is not cached on the VM ($MISSING) — it needs a Ship"
    continue
  fi
  CLASH=""
  for h in $(kv "$PF" PORT_HOLDERS); do
    case " $CNAMES " in *" $h "*) ;; *) CLASH="$CLASH $h" ;; esac
  done
  if [ -n "$CLASH" ]; then
    alert "reconcile: $DIR absent, port :$PORT taken" "$DIR on $VM is absent and its port :$PORT is held by:$CLASH — not starting it into a clash; re-allocate one of them"
    continue
  fi

  if [ "$MODE" != apply ]; then
    note "  would redeploy $DIR on $VM ($RP, $CF) — dry run"
    echo "would-redeploy $DIR"; exit 0
  fi

  note "  redeploying $DIR on $VM: docker compose up -d --no-recreate in $RP"
  OUT="$(up_script "$RP" "$CF" "$CNAMES" "$SETTLE" | remote "$VM")" || true
  printf '%s\n' "$OUT" | grep -v '^STATE \|^UP_RC=' >&2 || true
  BAD="$(printf '%s\n' "$OUT" | awk -v os=" $ONESHOT " '$1=="STATE" && $3!="running" && $3!="restarting" && !($3=="exited" && index(os, " "$2" ")) { print $2"="$3 }' | paste -sd' ' -)"
  if [ "$(kv "$OUT" UP_RC)" = "0" ] && [ -z "$BAD" ] && printf '%s\n' "$OUT" | grep -q '^STATE '; then
    note "  $DIR is back: $(printf '%s\n' "$OUT" | awk '$1=="STATE" { print $2"="$3 }' | paste -sd' ' -)"
    notify "reconcile: redeployed absent $DIR" "$DIR on $VM was absent; the reconcile ran docker compose up -d for it and it is running again."
    echo "redeployed $DIR"; exit 0
  fi
  note "::error::absent redeploy of $DIR on $VM did not come up (compose rc=$(kv "$OUT" UP_RC), not running: ${BAD:-unknown})"
  notify "reconcile: redeploy of absent $DIR FAILED" "$DIR on $VM is absent and docker compose up -d did not bring it back (not running: ${BAD:-unknown}). Needs a human or a Ship."
  echo "failed $DIR"; exit 1
done <<EOF_CANDS
$CANDS
EOF_CANDS

note "no absent service passed the checks — nothing redeployed this run"
echo "none"
exit 0
