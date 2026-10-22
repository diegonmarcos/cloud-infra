#!/usr/bin/env bash
# Tester for the graphrag stall QUARANTINE (#1061). Run 39688954936: octocode spun at 100%
# of a core for 87 minutes with no LLM call and no output, window after window, because the
# same few files were in flight each time. Properties:
#   1. the files a killed window had in flight (nodes added/described, from its log) are
#      extracted, limited to the window's new-work files;
#   2. chunk_quarantine records them with the reason, keeping earlier entries;
#   3. a quarantined file is never planned again, and is hidden from the walk;
#   4. a repo whose only outstanding files are quarantined is converged, and the status line
#      reports how many were quarantined;
#   5. a quarantined file is retried ALONE (marker so octocode rebuilds its node and edges, bounded
#      tries, released on success, named when it hangs alone);
#   6. CPU is NOT liveness: the stall watchdog does not reset on CPU alone.
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
    printf '%s\n' src/f1.ts src/f2.ts src/f3.ts > "$WORK/next"
    cat > "$WORK/log" <<L
✅ Updated description for: src/f0.ts
✅ Updated pending node description for: src/f2.ts
✅ Applied AI description to: src/f2.ts
➕ Added new node: src/f3.ts
➕ Added new node: src/not-in-window.ts
L
    # 1
    [ "$(chunk_inflight_from_log "$WORK/log" "$WORK/next" | tr '\n' ' ')" = "src/f2.ts src/f3.ts " ] || f "in-flight set is not {f2,f3} (only pending/added nodes inside the window)"
    # 2
    printf '{"v":1,"seen":"","chunk":3,"done":["src/f0.ts"],"dirty":[],"stale_runs":0,"quarantine":{"src/f5.ts":"older"}}\n' > "$WORK/s0"
    chunk_inflight_from_log "$WORK/log" "$WORK/next" > "$WORK/q"
    chunk_quarantine "$WORK/s0" "$WORK/q" "stalled test" "$WORK/s1"
    [ "$(jq -r '.quarantine | keys | join(",")' "$WORK/s1")" = "src/f2.ts,src/f3.ts,src/f5.ts" ] || f "quarantine did not merge with the earlier entry"
    [ "$(jq -r '.quarantine["src/f2.ts"]' "$WORK/s1")" = "stalled test" ] || f "reason not recorded"
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
    # 6: the retry of a quarantined file, alone
    [ "$(chunk_retry_marker src/a.ts)" = "// cgc-retry" ] || f "no // marker for .ts"
    [ "$(chunk_retry_marker x/y.py)" = "# cgc-retry" ] || f "no # marker for .py"
    [ -z "$(chunk_retry_marker data.json)" ] || f ".json cannot carry a marker, it must report none"
    printf '{"v":1,"seen":"","chunk":3,"done":[],"dirty":[],"stale_runs":0,"quarantine":{"src/f2.ts":"a","src/f3.ts":"b"},"quarantine_tries":{"src/f3.ts":2}}\n' > "$WORK/s3"
    [ "$(chunk_quarantine_pick "$WORK/s3" 2 | tr '\n' ' ')" = "src/f2.ts " ] || f "a file out of tries is still picked for a retry"
    chunk_quarantine_fail "$WORK/s3" src/f2.ts "hangs alone" "$WORK/s4"
    [ "$(jq -r '.quarantine_tries["src/f2.ts"]' "$WORK/s4")" = 1 ] && [ "$(jq -r '.quarantine["src/f2.ts"]' "$WORK/s4")" = "hangs alone" ] || f "a failed retry is not counted with its reason"
    chunk_quarantine_release "$WORK/s4" src/f2.ts "$WORK/s5"
    [ "$(jq -r '.quarantine | keys | join(",")' "$WORK/s5")" = "src/f3.ts" ] || f "a released file is still quarantined"
    jq -e '.quarantine_tries | has("src/f2.ts") | not' "$WORK/s5" >/dev/null || f "a released file keeps its try count"
    # the single-file window the retry plans: allowlist = that file, quarantine lifted for the plan
    chunk_quarantine_release "$WORK/s1" src/f2.ts "$WORK/s6"; printf 'src/f2.ts\n' > "$WORK/allow1"
    chunk_plan "$R" "$WORK/s6" "$H" 1 "$WORK/allow1" "$WORK/o7" >/dev/null
    [ "$(cat "$WORK/o7/next")" = "src/f2.ts" ] || f "the retry window is not exactly the one file: $(tr '\n' ' ' < "$WORK/o7/next")"
  ) && return 0 || return 1
}

fails=0
run_suite "$LIB" && echo "  ok   quarantine properties hold on the real library" || { echo "  FAIL real library" >&2; fails=1; }

# wiring: the update script retries quarantined files alone, from the loop, with a bounded budget
UPD="$REPO_ROOT/1_cicd/src/ops/cloud-cgc-db-update.sh"
if grep -q 'cgc_quarantine_retry_one "\$_cr_slice"' "$UPD" && grep -q 'CGC_QUARANTINE_BUDGET_MIN' "$UPD" && grep -q 'hangs ALONE' "$UPD"; then echo "  ok   the chunk loop retries quarantined files alone and names the ones that hang alone"; else echo "  FAIL retry of quarantined files is not wired into the chunk loop" >&2; fails=1; fi

# 5: CPU is not liveness (the watchdog resets only on progress or an LLM call)
if grep -q 'dcpu.*-ge' "$LIB"; then echo "  FAIL watchdog still treats CPU as liveness" >&2; fails=1; else echo "  ok   the stall watchdog does not reset on CPU"; fi

# mutations must go red
mut() { # $1 name  $2 sed expr
  sed "$2" "$LIB" > "$WORK/mut.sh"
  if run_suite "$WORK/mut.sh" >"$WORK/mut.out" 2>&1; then echo "  FAIL mutation '$1' survived (the test cannot go red)" >&2; fails=1; else echo "  ok   mutation '$1' goes red"; fi
}
mut "quarantine ignored by the plan" 's#comm -23 "$_cp_o/remaining" "$_cp_o/quarantine"#comm -23 "$_cp_o/remaining" /dev/null#'
mut "quarantine ignored by convergence" 's#chunk_quarantined_list "$1"; } | LC_ALL=C sort -u > "$_cv_t"#true; } | LC_ALL=C sort -u > "$_cv_t"#'
mut "retry ignores the try limit" 's#< \$m)#< 99)#'
mut "in-flight not limited to the window" 's#comm -12 - "$_if_t"#cat#'
exit "$fails"
