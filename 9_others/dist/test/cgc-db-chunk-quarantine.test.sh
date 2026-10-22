#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/cgc-db-chunk-quarantine.test.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Tester for the graphrag stall handling (#1061). Run 39688954936: octocode spun at 100% of a core
# for 87 minutes with no LLM call and no output, window after window, in the relationship-discovery
# phase that follows a window's file loop (it re-resolves the imports of every unchanged importer
# of the window's symbols). Properties:
#   1. chunk_quarantine records files with the reason, keeping earlier entries;
#   2. a quarantined file is never planned again and is hidden from the walk;
#   3. a repo whose only outstanding files are quarantined is converged, and the status line
#      reports how many were quarantined;
#   4. files a stalled window left without edges are forced in the next window: a marker line is
#      appended (comment syntax by extension) and git restores the file byte for byte afterwards;
#      a file without comment syntax is left alone; rework is cleared once the window succeeded;
#   5. CPU is NOT liveness: the stall watchdog does not reset on CPU alone;
#   6. the update script splits a stalled window by halving down to one file, and only a file that
#      hangs ALONE is quarantined, named in an ::error::.
# Each property is re-checked against a mutated library, which must fail.
set -uo pipefail
REPO_ROOT="$(_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
LIB="$REPO_ROOT/1_cicd/src/ops/cloud-cgc-db-chunk.sh"
[ -f "$LIB" ] || { echo "::error::chunk library not found at $LIB"; exit 1; }
command -v jq >/dev/null || { echo "::error::jq required"; exit 1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

run_suite() { # $1 lib → rc = failures
  local lib="$1" R="$WORK/r$RANDOM" O="$WORK/o$RANDOM" H
  (
    # shellcheck disable=SC1090
    . "$lib"
    f() { echo "  FAIL: $1"; exit 1; }
    mkdir -p "$R/src"; git init -q "$R"; git -C "$R" config user.email t@t; git -C "$R" config user.name t
    for i in 0 1 2 3 4 5; do echo "f$i" > "$R/src/f$i.ts"; done
    git -C "$R" add -A && git -C "$R" commit -qm init; H=$(git -C "$R" rev-parse HEAD)
    printf '%s\n' src/f2.ts src/f3.ts > "$WORK/q"
    printf '{"v":1,"seen":"","chunk":3,"done":["src/f0.ts"],"dirty":[],"stale_runs":0,"quarantine":{"src/f5.ts":"older"}}\n' > "$WORK/s0"
    # 1
    chunk_quarantine "$WORK/s0" "$WORK/q" "stalled test" "$WORK/s1"
    [ "$(jq -r '.quarantine | keys | join(",")' "$WORK/s1")" = "src/f2.ts,src/f3.ts,src/f5.ts" ] || f "quarantine did not merge with the earlier entry"
    [ "$(jq -r '.quarantine["src/f2.ts"]' "$WORK/s1")" = "stalled test" ] || f "reason not recorded"
    # 2
    chunk_plan "$R" "$WORK/s1" "$H" 10 "" "$O" >/dev/null
    grep -qE 'f2|f3|f5' "$O/chunk" && f "a quarantined file was planned"
    [ "$(tr '\n' ' ' < "$O/chunk")" = "src/f1.ts src/f4.ts " ] || f "window is not the remaining {f1,f4}: $(tr '\n' ' ' < "$O/chunk")"
    grep -q 'src/f2.ts' "$R/.git/info/exclude" || f "quarantined file not hidden from the walk"
    # 3
    chunk_plan "$R" "$WORK/s1" "$H" 10 "" "$O" >/dev/null
    grep -qE 'f2|f3|f5' "$O/chunk" && f "a quarantined file was planned"
    [ "$(tr '\n' ' ' < "$O/chunk")" = "src/f1.ts src/f4.ts " ] || f "window is not the remaining {f1,f4}: $(tr '\n' ' ' < "$O/chunk")"
    grep -q 'src/f2.ts' "$R/.git/info/exclude" || f "quarantined file not hidden from the walk"
    # 4
    printf '{"v":1,"seen":"","chunk":3,"done":["src/f0.ts","src/f1.ts","src/f4.ts"],"dirty":[],"stale_runs":0,"quarantine":{"src/f2.ts":"x","src/f3.ts":"x","src/f5.ts":"x"}}\n' > "$WORK/s2"
    chunk_exclude_clear "$R"; chunk_indexable "$R" > "$WORK/idx"; [ "$(wc -l < "$WORK/idx")" = 6 ] || f "indexable is not the 6 files"
    chunk_converged "$WORK/s2" "$WORK/idx" "" || f "a repo with only quarantined files left is not converged"
    [ "$(chunk_status_json r graphrag "$WORK/s2" "$WORK/idx" "$H" 1 | jq -r '"\(.quarantined) \(.remaining)"')" = "3 0" ] || f "status line does not report quarantined=3 remaining=0"
    # 4: rework forces files a stalled window left without edges
    [ "$(chunk_retry_marker src/a.ts)" = "// cgc-retry" ] || f "no // marker for .ts"
    [ "$(chunk_retry_marker x/y.py)" = "# cgc-retry" ] || f "no # marker for .py"
    [ -z "$(chunk_retry_marker data.json)" ] || f ".json cannot carry a marker, it must report none"
    printf 'data\n' > "$R/src/data.json"; git -C "$R" add -A; git -C "$R" commit -qm j
    printf '{"v":1,"done":[],"dirty":[],"rework":["src/f1.ts","src/data.json"]}\n' > "$WORK/s7"
    printf '%s\n' src/f1.ts src/f2.ts src/data.json > "$WORK/nx"
    before=$(git -C "$R" hash-object src/f1.ts 2>/dev/null || (cd "$R" && git hash-object src/f1.ts))
    chunk_rework_apply "$R" "$WORK/nx" "$WORK/s7" > "$WORK/marked"
    [ "$(cat "$WORK/marked")" = "src/f1.ts" ] || f "only the reworked file that can carry a marker is forced: $(tr '\n' ' ' < "$WORK/marked")"
    tail -n 1 "$R/src/f1.ts" | grep -q 'cgc-retry' || f "marker not appended"
    chunk_rework_restore "$R" "$WORK/marked"
    [ "$(cd "$R" && git hash-object src/f1.ts)" = "$before" ] || f "file not restored byte for byte"
    chunk_rework_add "$WORK/s7" "$WORK/nx" "$WORK/s8"
    [ "$(jq -r '.rework | length' "$WORK/s8")" = 3 ] || f "rework_add does not union"
    chunk_rework_clear "$WORK/s8" "$WORK/nx" "$WORK/s9"
    [ "$(jq -r '.rework | length' "$WORK/s9")" = 0 ] || f "rework_clear leaves the committed files"
  ) && return 0 || return 1
}

fails=0
run_suite "$LIB" && echo "  ok   quarantine properties hold on the real library" || { echo "  FAIL real library" >&2; fails=1; }

# wiring: the update script splits a stalled graphrag window and quarantines only a file that hangs ALONE
UPD="$REPO_ROOT/1_cicd/src/ops/cloud-cgc-db-update.sh"
if grep -q 'splitting: next window' "$UPD" && grep -q 'hangs ALONE' "$UPD" && grep -q 'CGC_ALONE_BUDGET_MIN' "$UPD" && grep -q 'chunk_rework_apply' "$UPD" && grep -q 'chunk_rework_restore' "$UPD"; then echo "  ok   a stalled window is split down to one file; only a file that hangs alone is quarantined"; else echo "  FAIL the split / alone-quarantine / rework wiring is missing from the chunk loop" >&2; fails=1; fi

# 5: CPU is not liveness (the watchdog resets only on progress or an LLM call)
if grep -q 'dcpu.*-ge' "$LIB"; then echo "  FAIL watchdog still treats CPU as liveness" >&2; fails=1; else echo "  ok   the stall watchdog does not reset on CPU"; fi

# mutations must go red
mut() { # $1 name  $2 sed expr
  sed "$2" "$LIB" > "$WORK/mut.sh"
  if run_suite "$WORK/mut.sh" >"$WORK/mut.out" 2>&1; then echo "  FAIL mutation '$1' survived (the test cannot go red)" >&2; fails=1; else echo "  ok   mutation '$1' goes red"; fi
}
mut "quarantine ignored by the plan" 's#comm -23 "$_cp_o/remaining" "$_cp_o/quarantine"#comm -23 "$_cp_o/remaining" /dev/null#'
mut "quarantine ignored by convergence" 's#chunk_quarantined_list "$1"; } | LC_ALL=C sort -u > "$_cv_t"#true; } | LC_ALL=C sort -u > "$_cv_t"#'
mut "rework never restores the file" 's#git -C "$1" checkout -q -- "$_rr_f" 2>/dev/null || true#true#'
mut "rework forces unmarkable files too" 's#\[ -n "$_rw_m" \] \&\& \[ -f#[ -f#'
exit "$fails"
