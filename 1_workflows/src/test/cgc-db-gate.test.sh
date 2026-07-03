#!/bin/sh
# Tester for the SMART gate logic in cloud-cgc-db-update.sh:
#   - change gate: skip a repo iff its HEAD == manifest[repo]
#   - budget gate: break iff elapsed >= max_minutes (0/empty = disabled)
# Mirrors the exact jq/arithmetic the producer uses. No octocode/docker needed.
set -eu
fail() { echo "FAIL: $1"; exit 1; }

M=$(mktemp); echo '{"cloud":"aaa111","unix":"bbb222"}' > "$M"

# change gate helper (same expression as the script)
skip() { # $1=repo $2=cur_head  -> echoes "skip" or "index"
  last=$(jq -r --arg r "$1" '.[$r] // ""' "$M")
  [ -n "$2" ] && [ "$2" = "$last" ] && echo skip || echo index
}

[ "$(skip cloud aaa111)" = skip ]  || fail "unchanged repo must skip"
[ "$(skip cloud ccc333)" = index ] || fail "moved HEAD must index"
[ "$(skip front zzz999)" = index ] || fail "repo absent from manifest must index"
[ "$(skip cloud '')"     = index ] || fail "empty HEAD (git failed) must index, not skip"

# manifest update (same as script) records the new sha
T=$(mktemp); jq --arg r front --arg c zzz999 '.[$r]=$c' "$M" > "$T" && mv "$T" "$M"
[ "$(jq -r '.front' "$M")" = zzz999 ] || fail "manifest must record indexed commit"

# budget gate arithmetic
budget_break() { # $1=elapsed_min $2=max_min -> "break" or "go"
  [ -n "$2" ] && [ "$2" != 0 ] && [ "$1" -ge "$2" ] && echo break || echo go
}
[ "$(budget_break 100 330)" = go ]    || fail "under budget must proceed"
[ "$(budget_break 330 330)" = break ] || fail "at budget must break"
[ "$(budget_break 999 0)"   = go ]    || fail "budget 0 disables the gate"

rm -f "$M"
echo "PASS: all cgc-db gate cases"
