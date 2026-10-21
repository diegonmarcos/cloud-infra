#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/cgc-db-chunk-stall.test.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# #1061 stall watchdog of chunk_heartbeat (cloud-cgc-db-chunk.sh).
#
# THE DEFECT: cloud-u-android's graphrag windows hang at "Indexing: 14279/14284 files" after
# 11 LLM calls and print nothing for the whole 90-minute window cap (runs 2026-10-20: chunks
# 2, 4 and 6 of one job, 4h46m for +300 files of 21k). The heartbeat only reported it. It now
# kills a window whose progress line and completed-call count stay put for the stall limit,
# and tells the caller through a flag file (update.sh turns that into the window's 124).
#
# Drives the real library with a stand-in "octocode" (a sleeping child of a wrapper, the
# same shape as `exec timeout N octocode index`) and a log the test writes itself.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/1_cicd/src/ops/cloud-cgc-db-chunk.sh"
UPD="$ROOT/1_cicd/src/ops/cloud-cgc-db-update.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }

FN="$(awk '/^chunk_heartbeat\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$LIB")"
[ -n "$FN" ] || { echo "::error::chunk_heartbeat() not found in $LIB"; exit 1; }
FN_TREE="$(awk '/^_hb_tree\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$LIB")"
[ -n "$FN_TREE" ] || { echo "::error::_hb_tree() not found in $LIB"; exit 1; }
eval "$FN_TREE"
eval "$FN"
export CGC_STALL_KILL_GRACE_S=1

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# A "window": subshell (pid file) -> timeout-like middle process -> sleeping octocode stand-in,
# the shape of `( cd d && timeout N octocode index ) &` (the pid is the subshell's).
start_window() { # $1 = case dir
  mkdir -p "$1"; : > "$1/log"
  ( sh -c 'sh -c "sleep 60" & wait' >/dev/null 2>&1 ) & echo $! > "$1/pid"
}
alive() { kill -0 "$(cat "$1/pid")" 2>/dev/null; }

# 1. progress printed once, then nothing: killed, flag set.
C="$W/stall"; start_window "$C"
echo "Indexing: 14279/14284 files" > "$C/log"
( chunk_heartbeat "t · chunk 1" "$C/log" "" 0 1 "$C/pid" 3 "$C/flag" >"$C/hb.out" 2>&1 ) &
HB=$!
for _ in $(seq 1 40); do [ -f "$C/flag" ] && break; sleep 1; done
wait "$HB" 2>/dev/null
[ -f "$C/flag" ] && ok "a window that stops moving is flagged as stalled" || bad "no flag after the stall limit"
sleep 1
alive "$C" && bad "the stalled window's process is still running" || ok "the stalled window is killed"
grep -q "stalled: no progress and no LLM call" "$C/hb.out" && ok "the stall is announced as a warning" || bad "no stall warning in the heartbeat output"
grep -q '/home\|\.kt' "$C/hb.out" && bad "the heartbeat printed a path" || ok "the heartbeat prints no paths"

# 2. progress keeps changing: never killed.
C="$W/moving"; start_window "$C"
( chunk_heartbeat "t · chunk 2" "$C/log" "" 0 1 "$C/pid" 3 "$C/flag" >"$C/hb.out" 2>&1 ) &
HB=$!
for i in 1 2 3 4 5 6 7; do echo "Indexing: $i/100 files" >> "$C/log"; sleep 1; done
kill "$HB" 2>/dev/null; wait "$HB" 2>/dev/null
[ -f "$C/flag" ] && bad "a window that keeps progressing was flagged" || ok "a window that keeps progressing is left alone"
alive "$C" && ok "and its process is untouched" || bad "a progressing window was killed"
kill "$(cat "$C/pid")" 2>/dev/null; for k in $(_hb_tree "$(cat "$C/pid")"); do kill "$k" 2>/dev/null; done

# 3. no progress line yet (slow start): not a stall.
C="$W/slowstart"; start_window "$C"
( chunk_heartbeat "t · chunk 3" "$C/log" "" 0 1 "$C/pid" 3 "$C/flag" >"$C/hb.out" 2>&1 ) &
HB=$!
sleep 7
kill "$HB" 2>/dev/null; wait "$HB" 2>/dev/null
[ -f "$C/flag" ] && bad "a window that has not printed a progress line yet was killed" || ok "a slow start (no progress line yet) is not a stall"
kill "$(cat "$C/pid")" 2>/dev/null; for k in $(_hb_tree "$(cat "$C/pid")"); do kill "$k" 2>/dev/null; done

# 4. new LLM calls count as movement even when the progress line is unchanged.
C="$W/calls"; start_window "$C"; : > "$C/calls"
echo "Indexing: 50/100 files" > "$C/log"
( chunk_heartbeat "t · chunk 4" "$C/log" "$C/calls" 0 1 "$C/pid" 3 "$C/flag" >"$C/hb.out" 2>&1 ) &
HB=$!
for i in 1 2 3 4 5 6 7; do echo '{"t":1,"kind":"desc","outcome":"ok","ms":10}' >> "$C/calls"; sleep 1; done
kill "$HB" 2>/dev/null; wait "$HB" 2>/dev/null
[ -f "$C/flag" ] && bad "a window still making LLM calls was killed" || ok "completed LLM calls count as progress"
kill "$(cat "$C/pid")" 2>/dev/null; for k in $(_hb_tree "$(cat "$C/pid")"); do kill "$k" 2>/dev/null; done

# 5. without the optional arguments the heartbeat never kills (semantic phase, old callers).
C="$W/optout"; start_window "$C"
echo "Indexing: 1/2 files" > "$C/log"
( chunk_heartbeat "t · chunk 5" "$C/log" "" 0 1 >"$C/hb.out" 2>&1 ) &
HB=$!
sleep 6
kill "$HB" 2>/dev/null; wait "$HB" 2>/dev/null
alive "$C" && ok "no stall arguments -> report only, nothing killed" || bad "the heartbeat killed a window it was not asked to watch"
kill "$(cat "$C/pid")" 2>/dev/null; for k in $(_hb_tree "$(cat "$C/pid")"); do kill "$k" 2>/dev/null; done

# 6. WIRING in update.sh: octocode runs in the background so the pid exists, the flag turns
#    into 124, and only the graphrag phase is watched.
BODY="$(awk '/^chunk_index_repo\(\)/,/^}/' "$UPD")"
grep -q '( cd "\$_cr_d" && timeout "\${_cr_wto}m" octocode index ) >"\$_log" 2>&1 &' <<<"$BODY" && ok "octocode index runs as a background timeout child (killable by pid)" || bad "octocode index is no longer started in the background"
grep -q '\[ -f "\$_cr_stalled" \] && _rc=124' <<<"$BODY" && ok "a ordered stall kill is reported as the window's 124" || bad "the stall flag is not turned into rc 124"
grep -q '"\$MANIFEST_PHASE" = "graphrag" \] && _cr_stall_s=' <<<"$BODY" && ok "only the graphrag phase is watched" || bad "stall watching is not gated on the graphrag phase"
grep -q 'chunk_heartbeat .*"\$_cr_pidf" "\$_cr_stall_s" "\$_cr_stalled"' <<<"$BODY" && ok "the heartbeat receives pid file, limit and flag" || bad "chunk_heartbeat is not given the stall arguments"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
