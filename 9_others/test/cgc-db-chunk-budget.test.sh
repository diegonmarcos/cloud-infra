#!/usr/bin/env bash
# #888: the chunk loop's budget behaviour, driven end to end on a simulated clock.
#
# THE FAILURES IT GUARDS, both measured on run 37929244331 (cloud-u-android, semantic):
#   1. DOUBLE PUBLISH. Chunk 1 finished at 18:26, the loop checkpoint-published it
#      (58m), found no slice left for chunk 2, returned -- and the outer per-repo loop
#      published the very same index again (another 58m). One stop, one publish.
#   2. A WINDOW THAT CANNOT FINISH. The loop planned a fixed 3000-file window whatever
#      was left of the budget. A window that times out keeps nothing (octocode records
#      skip state only for a COMPLETED run), so the last slice of every run was burnt.
#      Windows must be sized to the slice from the measured per-file rate.
#
# chunk_index_repo() is extracted BY NAME from cloud-cgc-db-update.sh and run against
# the real planner library on a real git repo; only octocode, timeout, date and the
# publish are stubbed, and they move a fake clock instead of sleeping. Scale: 1/10 of
# android (300-file default chunk at 24 s/file = 120 min, like 3000 at 2.4 s/file).
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
i=0; while [ $i -lt 2300 ]; do printf 'x%s\n' $i > "$R/src/f$i.kt"; i=$((i + 1)); done
git -C "$R" add -A && git -C "$R" commit -qm init
HEAD_SHA=$(git -C "$R" rev-parse HEAD)

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ok: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1"; }

# scenario <name> <startup min> <publish min> <budget min> <reserve min> [ms/file of window 1] [ms/file after]
#   → writes $W/<name>.events. Without the two rates every file costs 24 s.
scenario() {
  local name="$1" startup="$2" pubm="$3" budget="$4" reserve="$5" r1="${6:-24000}" r2="${7:-24000}"
  echo 0 > "$W/calls"
  rm -rf "${W:?}/home" "${W:?}/scratch" "$R/.git/info/exclude"; mkdir -p "$W/home/p1" "$W/scratch"
  CLOCK="$W/clock"; EV="$W/$name.events"; : > "$EV"; echo $(( startup * 60 )) > "$CLOCK"
  (
    # shellcheck disable=SC1090
    . "$LIB"
    eval "$FN"
    date() { cat "$CLOCK"; }
    timeout() { local m="${1%m}"; shift; LIMIT=$(( m * 60 )) "$@"; }
    octocode() {
      local n need c; n=$(wc -l < "$_cr_o/next" | tr -d ' '); c=$(( $(cat "$W/calls") + 1 )); echo "$c" > "$W/calls"
      if [ "$c" = 1 ]; then need=$(( n * r1 / 1000 )); else need=$(( n * r2 / 1000 )); fi
      if [ "$need" -gt "$LIMIT" ]; then echo $(( $(cat "$CLOCK") + LIMIT )) > "$CLOCK"; echo "index $n timeout" >> "$EV"; return 124; fi
      echo $(( $(cat "$CLOCK") + need )) > "$CLOCK"; echo "index $n ok" >> "$EV"; return 0
    }
    checkpoint_publish() { echo $(( $(cat "$CLOCK") + pubm * 60 )) > "$CLOCK"; echo "publish" >> "$EV"; }
    chunk_home_project() { echo p1; }
    resolve_project_dir() { echo p1; }
    force_partial_tag() { echo latest-force; }
    OCTO_HOME="$W/home" CGC_SCRATCH="$W/scratch" MANIFEST_PHASE=semantic CGC_FORCE=0
    START_TS=0 BUDGET_MIN="$budget" REPO_TIMEOUT_EFF=$(( budget - startup ))
    CHUNK_N_DEFAULT=300 CHUNK_MIN=10 CHUNK_MAX=2000 CHUNK_STALE_ALERT=99 CHUNK_FILL_PCT=80
    CHUNK_PUBLISH_RESERVE_MIN="$reserve" GITHUB_STEP_SUMMARY=""
    unset CGC_CHUNK_FILES
    _before_dirs="" _idx_marker="" _proj_resolved=""
    chunk_index_repo cloud-u-android "$R" "$HEAD_SHA" >"$W/$name.log" 2>&1
    # The outer per-repo loop's publish, which always follows a chunk-mode return.
    checkpoint_publish
    echo "end $(( $(cat "$CLOCK") / 60 )) done $(jq '.done | length' "$W/home/p1/.cgc-chunks-semantic.json")" >> "$EV"
  )
}

# 1. Run 37929244331's timings: 60m startup, 58m publishes, 240m budget, 40m reserve.
scenario slow 60 58 240 40
if awk 'prev == "publish" && $0 == "publish" { d = 1 } { prev = $0 } END { exit !d }' "$W/slow.events"; then
  bad "an in-loop checkpoint publish was followed straight by the outer publish of the same index: $(tr '\n' ',' < "$W/slow.events")"
else
  ok "one stop, one publish (run 37929244331 timings): $(tr '\n' ',' < "$W/slow.events")"
fi

# 2. After the integrity-scan fix: 4m startup, 1m publishes, 285m budget, 15m reserve.
scenario fast 4 1 285 15
if grep -q timeout "$W/fast.events"; then
  bad "a window was planned that could not finish in its slice (its work is lost): $(tr '\n' ',' < "$W/fast.events")"
else
  ok "every window completed: $(tr '\n' ',' < "$W/fast.events")"
fi
read -r _ end_min _ done_n < <(tail -1 "$W/fast.events")
[ "${done_n:-0}" -ge 600 ] && ok "fast run indexed $done_n files (>= 2x the 300-file default chunk)" \
  || bad "fast run indexed only ${done_n:-0} files in a 285m budget"
[ "${end_min:-999}" -le 285 ] && ok "fast run ended at ${end_min}m, inside the 285m budget" \
  || bad "fast run ended at ${end_min}m, past the 285m budget"
awk 'prev == "publish" && $0 == "publish" { d = 1 } { prev = $0 } END { exit !d }' "$W/fast.events" \
  && bad "fast run double-published" || ok "fast run never double-published"
grep -q '"ms_per_file"' "$W/home/p1/.cgc-chunks-semantic.json" && ok "the measured rate travels in the chunk state" \
  || bad "no ms_per_file in the chunk state, so the next run's first window cannot be sized"

# 3. Run 38044529950, cloud-u-android semantic: window 1 was mostly files already embedded
#    (3031 at 230 ms/file); the rate then planned all 15387 remaining files into one 263m
#    window, which walked 74% of them at ~1.07 s/file and died. Scale 1/10: 300-file
#    default chunk, 1538 more files, window 1 at 230 ms/file, then 10.7 s/file.
i=2300; while [ $i -lt 3838 ]; do printf 'x%s\n' $i > "$R/src/f$i.kt"; i=$((i + 1)); done
git -C "$R" add -A && git -C "$R" commit -qm more && HEAD_SHA=$(git -C "$R" rev-parse HEAD)
scenario android 4 1 285 15 230 10700
if grep -q timeout "$W/android.events"; then
  bad "a cheap first window sized the next one past the slice (run 38044529950): $(tr '\n' ',' < "$W/android.events")"
else
  ok "android replay: every window completed: $(tr '\n' ',' < "$W/android.events")"
fi
read -r _ _ _ done_n < <(tail -1 "$W/android.events")
[ "${done_n:-0}" -ge 1500 ] && ok "android replay: $done_n files durable in one job" || bad "android replay: only ${done_n:-0} files durable"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ] || { echo FAIL; exit 1; }
echo PASS
