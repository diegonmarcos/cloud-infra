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

# smart_noindex detection: exclude a dir iff >=min_files AND >=binary_ratio binary (git numstat '-')
detect() { # stdin=numstat lines, args: min ratio -> excluded dirs
  awk -v min="$1" -v ratio="$2" '
    { path=$3; if (path=="" || path !~ /\//) next; dir=path; sub(/\/[^\/]*$/,"",dir);
      tot[dir]++; if ($1=="-") bin[dir]++; }
    END { for (d in tot) if (tot[d]>=min && (bin[d]+0)/tot[d]>=ratio) print d"/"; }'
}
# 20 binary files in assets/ -> excluded
out=$(printf -- '-\t-\tassets/i%02d.png\n' $(seq 1 20) | detect 12 0.5)
[ "$out" = "assets/" ] || fail "binary-dominated dir must be excluded (got '$out')"
# a source dir (all text, add counts numeric) -> NOT excluded
out=$(printf '5\t2\tsrc/f%02d.kt\n' $(seq 1 20) | detect 12 0.5)
[ -z "$out" ] || fail "source dir must NOT be excluded (got '$out')"
# below min_files even if all binary -> NOT excluded
out=$(printf -- '-\t-\ticons/i%d.svg\n' $(seq 1 5) | detect 12 0.5)
[ -z "$out" ] || fail "dir under min_files must NOT be excluded (got '$out')"
# mixed just over ratio (7 bin / 12) -> excluded
out=$(printf -- '-\t-\tmix/b%d.png\n' $(seq 1 7); printf '1\t0\tmix/s%d.js\n' $(seq 1 5))
out=$(printf '%s' "$out" | detect 12 0.5)
[ "$out" = "mix/" ] || fail "dir over binary_ratio must be excluded (got '$out')"

rm -f "$M"
echo "PASS: all cgc-db gate + smart-noindex cases"
