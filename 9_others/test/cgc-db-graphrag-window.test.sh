#!/usr/bin/env bash
# #888: graphrag windows are time-capped, a stalled window cannot eat the job, LLM
# deferrals stay outstanding, and every window reports its LLM work.
#
# THE FAILURE IT GUARDS, measured on run 37929244331 (cloud-u-containers, graphrag):
#   window 1: 1000 files in 1466s. The chunk then doubled to 2000 and window 2 ran with
#   `timeout <whole 204m slice>`; it finished its description pass, sat in "AI analyzing
#   1681 files for architectural relationships" (octocode/octolib send LLM calls with no
#   request timeout) until the slice expired, and the loop BROKE: one stalled window
#   took the rest of the job and kept nothing.
#
# chunk_index_repo() and the planner library run for real on a real git repo; octocode,
# timeout, date and the publish are stubbed and move a fake clock. The stub charges the
# measured 1.466 s per new-work file plus 0.3 s per already-done file (octocode re-runs AI
# relationship analysis for done files that import the window's symbols, so graphrag gets
# slower as the done set grows), and its SECOND call hangs until it is killed.
# The scenario subshell sets the globals chunk_index_repo() reads (SC2034) and stubs
# octocode against its plan dir (SC2154).
# shellcheck disable=SC2034,SC2154
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
UPD="$ROOT/1_cicd/src/ops/cloud-cgc-db-update.sh"
LIB="$ROOT/1_cicd/src/ops/cloud-cgc-db-chunk.sh"
command -v jq >/dev/null || { echo "::error::jq required"; exit 1; }
FN="$(awk '/^chunk_index_repo\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$UPD")"
case "$FN" in *"chunk_index_repo()"*) : ;; *) echo "::error::could not extract chunk_index_repo() from $UPD"; exit 1 ;; esac

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
R="$W/repo"; mkdir -p "$R/src"; git init -q "$R"
git -C "$R" config user.email t@t; git -C "$R" config user.name t
i=0; while [ $i -lt 4355 ]; do printf 'x%s\n' $i > "$R/src/f$i.ts"; i=$((i + 1)); done
git -C "$R" add -A && git -C "$R" commit -qm init
HEAD_SHA=$(git -C "$R" rev-parse HEAD)

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ok: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1"; }

CLOCK="$W/clock"; EV="$W/events"; LLM="$W/llm.jsonl"; : > "$EV"; : > "$LLM"
echo $(( 4 * 60 )) > "$CLOCK"
rm -rf "${W:?}/home" "${W:?}/scratch"; mkdir -p "$W/home/p1" "$W/scratch"
(
  # shellcheck disable=SC1090
  . "$LIB"
  eval "$FN"
  date() { cat "$CLOCK"; }
  timeout() { local m="${1%m}"; shift; LIMIT=$(( m * 60 )) "$@"; }
  echo 0 > "$W/calls"
  octocode() {  # runs in a subshell: the call counter lives in a file
    local CALLS; CALLS=$(( $(cat "$W/calls") + 1 )); echo "$CALLS" > "$W/calls"
    local n d need now; n=$(wc -l < "$_cr_o/next" | tr -d ' '); d=$(wc -l < "$_cr_o/done" | tr -d ' ')
    now=$(cat "$CLOCK")
    echo "limit $(( LIMIT / 60 ))" >> "$EV"
    if [ "$CALLS" = "2" ]; then
      # The deferred paths of window 1 must be outstanding and re-planned here.
      local p; while IFS= read -r p; do
        jq -e --arg p "$p" '.done | index($p) == null' "$_cr_sf_stage" >/dev/null || echo "deferred-done $p" >> "$EV"
        grep -qxF "$p" "$_cr_o/next" || echo "deferred-not-replanned $p" >> "$EV"
      done < "$W/deferred.expect"
      echo $(( now + LIMIT )) > "$CLOCK"; echo "index $n stall" >> "$EV"; return 124
    fi
    need=$(( n * 1466 / 1000 + d * 3 / 10 ))
    if [ "$need" -gt "$LIMIT" ]; then echo $(( now + LIMIT )) > "$CLOCK"; echo "index $n timeout" >> "$EV"; return 124; fi
    echo $(( now + need )) > "$CLOCK"; echo "index $n ok $(( need / 60 ))m" >> "$EV"
    # What the LLM proxy logs for this window: calls, one description batch given up on.
    printf '{"t":%s,"kind":"desc","files":8,"outcome":"ok","ms":4000,"attempts":1,"timeouts":0,"r429":0,"r5xx":0,"neterr":0,"wait_s":0,"out_tokens":600}\n' "$now" >> "$LLM"
    printf '{"t":%s,"kind":"rel","files":8,"outcome":"degraded","ms":360000,"attempts":3,"timeouts":3,"r429":0,"r5xx":0,"neterr":0,"wait_s":6}\n' "$now" >> "$LLM"
    if [ "$CALLS" = "1" ]; then
      head -n 2 "$_cr_o/next" > "$W/deferred.expect"
      jq -R . "$W/deferred.expect" | jq -s -c --arg t "$now" '{t: ($t | tonumber), kind: "desc", files: 8, outcome: "deferred", ms: 360000, attempts: 3, timeouts: 0, r429: 2, r5xx: 1, neterr: 0, wait_s: 61, deferred: .}' >> "$LLM"
    fi
    return 0
  }
  checkpoint_publish() { echo $(( $(cat "$CLOCK") + 60 )) > "$CLOCK"; echo "publish" >> "$EV"; }
  chunk_home_project() { echo p1; }
  resolve_project_dir() { echo p1; }
  force_partial_tag() { echo latest-force; }
  OCTO_HOME="$W/home" CGC_SCRATCH="$W/scratch" MANIFEST_PHASE=graphrag CGC_FORCE=0
  START_TS=0 BUDGET_MIN=300 REPO_TIMEOUT_EFF=296
  CHUNK_N_DEFAULT=1000 CHUNK_MIN=100 CHUNK_MAX=20000 CHUNK_STALE_ALERT=99 CHUNK_FILL_PCT=80
  CHUNK_PUBLISH_RESERVE_MIN=15 GITHUB_STEP_SUMMARY=""
  CHUNK_GR_WINDOW_MIN=45 CHUNK_GR_TIMEOUT_MIN=90 LLM_PROXY_LOG="$LLM"
  unset CGC_CHUNK_FILES CGC_HEARTBEAT_S
  _before_dirs="" _idx_marker="" _proj_resolved=""
  chunk_index_repo cloud-u-containers "$R" "$HEAD_SHA" >"$W/run.log" 2>&1
  checkpoint_publish
  echo "end $(( $(cat "$CLOCK") / 60 )) done $(jq '.done | length' "$W/home/p1/.cgc-chunks-graphrag.json")" >> "$EV"
)
echo "  events: $(tr '\n' ',' < "$EV")"

# 1. No window may run longer than the graphrag window timeout, whatever the slice.
maxlim=$(awk '$1 == "limit" && $2 > m { m = $2 } END { print m + 0 }' "$EV")
[ "$maxlim" -gt 0 ] && [ "$maxlim" -le 90 ] && ok "every window is killed by 90m at the latest (max timeout ${maxlim}m)" \
  || bad "a window ran under a ${maxlim}m timeout — one stalled LLM call can hold it that long"

# 2. The stalled window does not end the job: later windows still make durable progress.
if grep -q stall "$EV" && awk '/stall/ { s = 1; next } s && / ok / { found = 1 } END { exit !found }' "$EV"; then
  ok "windows after the stalled one completed in the same job"
else
  bad "nothing completed after the stalled window — it took the rest of the job"
fi
read -r _ end_min _ done_n < <(tail -1 "$EV")
[ "${end_min:-999}" -le 300 ] && ok "the job ended at ${end_min}m, inside its 300m budget" || bad "the job ended at ${end_min}m, past its budget"
[ "${done_n:-0}" -ge 3000 ] && ok "$done_n of 4355 files done in one job despite the stall" || bad "only ${done_n:-0} files done"

# 3. Completed windows stay inside the planning cap (45m of work + the 20% fill margin).
over=$(awk '$1 == "index" && $3 == "ok" { m = $4; sub(/m$/, "", m); if (m + 0 > 45) print $0 }' "$EV")
[ -z "$over" ] && ok "every completed window used <= 45m" || bad "a window planned past the 45m cap: $over"

# 4. Files whose description call was given up on stay outstanding and are re-planned.
[ -s "$W/deferred.expect" ] || bad "the stub never recorded deferred files"
if grep -q 'deferred-' "$EV"; then bad "deferred files were committed as done: $(grep deferred- "$EV" | tr '\n' ' ')"
else ok "deferred files stayed outstanding and went into the next window"; fi

# 5. Each window reports its LLM work.
grep -q 'LLM [0-9]* calls ([0-9]* desc, [0-9]* rel)' "$W/run.log" \
  && ok "per-window LLM summary: $(grep -m1 'LLM [0-9]* calls' "$W/run.log" | sed 's/^\[cgc-db\] //')" \
  || bad "no per-window LLM summary line"
grep -q '1 deferred = 2 files kept outstanding' "$W/run.log" && ok "the summary counts the deferred files" \
  || bad "the summary does not count the deferred files"

# 6. The heartbeat prints numeric progress only (private repos log here too).
HB="$W/hb.log"; printf 'Collecting for AI batch: secret/path.rs\r Indexing: 37/120 files (30%%)\n' > "$W/octo.log"
printf '{"t":1,"kind":"rel","outcome":"ok","ms":5000}\n' > "$W/hb.jsonl"
( # shellcheck disable=SC1090
  . "$LIB"; chunk_heartbeat "repo · chunk 1" "$W/octo.log" "$W/hb.jsonl" 0 1 > "$HB" 2>&1 ) & hbp=$!
sleep 2.5; kill "$hbp" 2>/dev/null; wait "$hbp" 2>/dev/null
if grep -q 'heartbeat .*Indexing: 37/120 files; LLM calls done 1' "$HB" && ! grep -q secret "$HB"; then
  ok "heartbeat: $(head -1 "$HB")"
else
  bad "heartbeat missing or leaks a path: $(head -2 "$HB" | tr '\n' ' ')"
fi

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ] || { echo FAIL; sed -n '1,80p' "$W/run.log"; exit 1; }
echo PASS
