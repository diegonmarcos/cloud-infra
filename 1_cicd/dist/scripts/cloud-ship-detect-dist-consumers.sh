#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_cicd/src/scripts/cloud-ship-detect-dist-consumers.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ── Which services does a regenerated build-*.json actually oblige to redeploy? ──
#
# Reverse-walks a_solutions/*/src/*.json symlinks to find the service that consumes each
# changed 1_cloud-configs/dist/build-*.json, then decides SHIP or SKIP per consumer AND
# prints the reason for every single decision.
#
# WHY this is a script and not more shell inside ship.yml's detect step: this decision
# ships, or silently fails to ship, every service in the fleet. While it lived inline in a
# 1180-line workflow it could not be driven with synthetic input, so neither direction was
# ever asserted — a false skip and a false deploy looked identical from the outside, and
# diagnosing one cost a full investigation. 9_others/test/test_detect_dist_consumers.sh
# now drives this file directly.
#
# WHY the SKIP branch exists at all: cloud-data-config-derive.ts stamps a fleet-wide
# cross-service registry into EVERY per-service build-*.json (its own doc comment calls it
# the "cross-service registry map (every peer's ip/ports/vm/api/mcp)"). Registering two
# unrelated MCP endpoints on 2026-09-05 (96e362760) rewrote 115 of those files; 104 of the
# 115 diffs contained nothing but that registry. The old file-granular walk read "the file
# changed" as "the service changed" and redeployed 43 services on oci-apps — among them
# cloud-ide (user-prod_code-server), whose compose.nix reads buildJson.containers.app and
# never touches the registry. Same shape as the Collabora/Office-Sheets rebuild before it.
#
# WHY it cannot cause the opposite, worse failure (a green ship that deployed nothing):
# every branch except one ends in SHIP. A consumer is skipped ONLY when both hold, and
# either being unprovable ships it:
#   1. every changed top-level key of its build-*.json is declared broadcast in
#      9_others/ship-dist-broadcast-blocks.json — so nothing the service OWNS changed; and
#   2. nothing under a_solutions/<dir>/src/ binds that block (`<ident>.<block>`) — so the
#      service's own render cannot observe the change even in principle.
# Missing data file, missing src/, unparseable JSON, absent jq: all ship.
#
# Usage: cloud-ship-detect-dist-consumers.sh <base-rev> <head-rev>
#   cwd (or any parent) must be the cloud-infra checkout, with a_solutions/ populated.
#   stdout: ONE line, the space-separated service dirs to ship (possibly empty).
#   stderr: one tab-separated decision per consumer per changed file, plus the
#           ::notice:: summaries —
#     SHIP<TAB><service-dir><TAB><dist-file><TAB><reason>
#     SKIP<TAB><service-dir><TAB><dist-file><TAB><reason>
#
# The split is deliberate. Everything the caller must PARSE is one stdout line it
# can assign directly; everything a human must READ goes to stderr, which GHA
# interleaves into the step log. Keeping the loop, the awk and the reason
# formatting on this side of the boundary means ship.yml's detect step gains one
# assignment rather than thirty more lines of shell embedded in YAML — and the
# first attempt at this change did embed them, which left ship.yml unparseable by
# GHA (run 34445801635: zero jobs, the workflow's registered name reverting from
# 'Ship' to its own path) while every local YAML and `bash -n` check passed.

set -uo pipefail

BASE="${1:?usage: cloud-ship-detect-dist-consumers.sh <base-rev> <head-rev>}"
HEAD_REV="${2:?usage: cloud-ship-detect-dist-consumers.sh <base-rev> <head-rev>}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT" || exit 1

BROADCAST_JSON="9_others/ship-dist-broadcast-blocks.json"

emit() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >&2; }

# ── The declared broadcast blocks ────────────────────────────────────────────────
# An unreadable or absent declaration leaves this EMPTY, which makes every changed key
# count as service-owned and ships every consumer. That is the safe direction: a missing
# data file must never be able to suppress a deploy.
BROADCAST_KEYS=""
if [ -f "$BROADCAST_JSON" ]; then
  BROADCAST_KEYS=$(jq -r '.broadcast_blocks[]?' "$BROADCAST_JSON" 2>/dev/null | tr '\n' ' ')
fi
if [ -z "$BROADCAST_KEYS" ]; then
  echo "::warning::detect: $BROADCAST_JSON missing or unreadable — treating every changed key as service-owned (shipping every dist consumer)" >&2
fi

_is_broadcast() {
  case " $BROADCAST_KEYS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# ── Consumer index: absolute dist path → service dir ──────────────────────────────
# Resolved once. Same one-level walk over a_solutions/*/src/*.json the detect step has
# always used — the symlink layout the derive step creates, not a wider guess.
LINKS_TSV="$(mktemp)"
trap 'rm -f "$LINKS_TSV" "${TMP_OLD:-}" "${TMP_NEW:-}"' EXIT
for _svc_dir in a_solutions/*/src; do
  [ -d "$_svc_dir" ] || continue
  for _link in "$_svc_dir"/*.json; do
    [ -L "$_link" ] || continue
    _target=$(readlink -f "$_link" 2>/dev/null || true)
    [ -n "$_target" ] || continue
    printf '%s\t%s\n' "$_target" "$(printf '%s' "$_svc_dir" | awk -F/ '{print $2}')" >> "$LINKS_TSV"
  done
done

TMP_OLD="$(mktemp)"
TMP_NEW="$(mktemp)"

# Top-level keys whose value differs between the two revisions. A file absent on one side
# is read as {}, so an added or deleted dist file reports all of its keys as changed.
# Prints the sentinel __UNPARSEABLE__ when either side is not JSON, which ships.
_changed_keys() {
  git show "$BASE:$1"     > "$TMP_OLD" 2>/dev/null || printf '{}' > "$TMP_OLD"
  git show "$HEAD_REV:$1" > "$TMP_NEW" 2>/dev/null || printf '{}' > "$TMP_NEW"
  # -r is load-bearing: without it every key arrives quoted ("services") and can never
  # match the unquoted names in the broadcast declaration, so every change reads as
  # service-owned and nothing is ever suppressed.
  jq -rn --slurpfile o "$TMP_OLD" --slurpfile n "$TMP_NEW" '
      (($o[0] // {}) | if type == "object" then . else error("not an object") end) as $O
    | (($n[0] // {}) | if type == "object" then . else error("not an object") end) as $N
    | (($O | keys) + ($N | keys) | unique)
    | map(select($O[.] != $N[.]))
    | .[]
  ' 2>/dev/null || printf '__UNPARSEABLE__\n'
}

# Which entries INSIDE a broadcast block changed. Purely for the reason string, and that
# string is the point: it turns "43 services redeployed" into "43 services redeployed
# because services.cloud-superapp-mcp was added" at a glance.
_changed_entries() {
  jq -rn --slurpfile o "$TMP_OLD" --slurpfile n "$TMP_NEW" --arg blk "$1" '
      (($o[0] // {})[$blk] // {}) as $O
    | (($n[0] // {})[$blk] // {}) as $N
    | if ($O | type) != "object" or ($N | type) != "object" then "<whole block>"
      else (($O | keys) + ($N | keys) | unique | map(select($O[.] != $N[.])) | join(","))
      end
  ' 2>/dev/null
}

# Does anything the service actually builds from bind this block? `<ident>.<block>` is how
# every consumer reads it (compose.nix: `svc = container.services;` then `svc.dagu.ip`).
# It deliberately does NOT match compose.nix's own OUTPUT key `services = { ... }`, which
# every service has and which says nothing about reading the registry. grep -r does not
# descend symlinks, so the symlinked build-*.json — whose literal `"services":` would match
# nothing here anyway — is not consulted.
_binds_block() {
  [ -d "a_solutions/$1/src" ] || return 0   # no src to inspect: cannot prove it safe, ship
  grep -rqE "[A-Za-z_][A-Za-z0-9_'-]*\.${2}\b" \
      --exclude-dir=node_modules --exclude-dir=.git \
      "a_solutions/$1/src" 2>/dev/null
}

DECISIONS="$(mktemp)"
trap 'rm -f "$LINKS_TSV" "${TMP_OLD:-}" "${TMP_NEW:-}" "${DECISIONS:-}"' EXIT

{
git diff --name-only "$BASE" "$HEAD_REV" -- '1_cloud-configs/dist/build-*.json' 2>/dev/null \
| while IFS= read -r _df; do
  [ -n "$_df" ] || continue
  _df_abs="$REPO_ROOT/$_df"

  _keys=$(_changed_keys "$_df")
  _owned=""; _bcast=""
  for _k in $_keys; do
    if _is_broadcast "$_k"; then _bcast="$_bcast $_k"; else _owned="$_owned $_k"; fi
  done
  _owned="${_owned# }"; _bcast="${_bcast# }"

  while IFS=$'\t' read -r _target _svc; do
    [ "$_target" = "$_df_abs" ] || continue

    if [ -z "$_keys" ]; then
      # Path listed by git diff with no top-level key differing: formatting or key
      # reordering only. Nothing a consumer can read changed, so nothing to deploy.
      emit SKIP "$_svc" "$_df" "no top-level key differs (whitespace/ordering only)"
      continue
    fi

    if [ -n "$_owned" ]; then
      emit SHIP "$_svc" "$_df" "own declaration changed: ${_owned// /,}"
      continue
    fi

    _reason_detail=""
    for _b in $_bcast; do
      _reason_detail="${_reason_detail}${_reason_detail:+; }${_b}: $(_changed_entries "$_b")"
    done

    _bound=""
    for _b in $_bcast; do
      if _binds_block "$_svc" "$_b"; then _bound="$_b"; break; fi
    done

    if [ -n "$_bound" ]; then
      emit SHIP "$_svc" "$_df" "reads the '$_bound' registry, which changed ($_reason_detail)"
    else
      emit SKIP "$_svc" "$_df" "only fleet-wide broadcast changed ($_reason_detail) and a_solutions/$_svc/src never binds ${_bcast// /,}"
    fi
  done < "$LINKS_TSV"
done
} 2> "$DECISIONS"

# Replay every decision into the caller's log, then summarise. SHIP wins over
# SKIP for a service that consumes several dist files: one genuinely-changed
# declaration obliges the deploy no matter how many other files only carried
# broadcast churn.
cat "$DECISIONS" >&2

SHIP_DIRS=$(awk -F'\t' '$1=="SHIP"{print $2}' "$DECISIONS" | sort -u | tr '\n' ' ')
SUPPRESSED=$(awk -F'\t' '$1=="SHIP"{s[$2]=1} $1=="SKIP"{k[$2]=1}
  END{for (x in s) delete k[x]; for (x in k) print x}' "$DECISIONS" | sort -u | tr '\n' ' ')

echo "::notice::dist-consumer ship: ${SHIP_DIRS:-<none>}" >&2
if [ -n "$SUPPRESSED" ]; then
  echo "::notice::dist-consumer NOT shipped (only the fleet-wide registry changed and they never read it): $SUPPRESSED" >&2
fi

printf '%s' "$SHIP_DIRS"
