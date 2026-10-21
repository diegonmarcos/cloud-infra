#!/usr/bin/env bash
# #1073 - cloud-infra reads the repo list from ONE place: git-repos-master/repos.json.
# 1_cloud-configs/src/inputs/repos.sot.json is its byte copy (git-repos-master's ./clone.sh --sync
# refreshes it). This tester fails when
#   S1  the copy is not a valid cloud-repos/v1 registry, or differs from the registry at its declared url
#       (checked when the network answers; offline is reported, S2-S6 still run)
#   S2  a fleet.repos[] entry (0_apps/src/manifest.json) is not in the registry, is pending_creation,
#       or disagrees about private
#   S3  a pending_creation repo (cloud-webapps, cloud-me-containers) is already on GitHub (flip its status),  or a repo once declared pending (cloud-webapps, cloud-me-containers) leaves the registry,
#       or is in the fleet manifest
#   S4  a GitHub repo of the fetched inventory (github-repos.json) is neither registered nor in unregistered_ok
#   S5  a live registry repo is missing from the inventory, or the old name of a rename is still used as a
#       fleet github name (cloud-mobile -> cloud-superapp, ffront -> front)
#   S6  the guard bites (a mutated copy is caught)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SOT="$ROOT/1_cloud-configs/src/inputs/repos.sot.json"
M="$ROOT/0_apps/src/manifest.json"
INV="$ROOT/1_cloud-configs/src/inputs/github-repos.json"
URL="${REPOS_SOT_URL:-https://raw.githubusercontent.com/diegonmarcos/git-repos-master/claude/new-session-vb0job/repos.json}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
GH='(.url|sub("^.*[/:]";"")|sub("\\.git$";""))'

jq -e '._schema=="cloud-repos/v1" and (.repos|length)>5 and (([.repos[].name]|length) == ([.repos[].name]|unique|length))' "$SOT" >/dev/null 2>&1 \
  && ok "S1a repos.sot.json is a valid cloud-repos/v1 registry" || bad "S1a repos.sot.json invalid"
# raw.githubusercontent.com is CDN-cached for minutes after a push: ask the contents API (always fresh) first.
API="$(printf '%s' "$URL" | sed -E 's#^https://raw.githubusercontent.com/([^/]+)/([^/]+)/(.+)/([^/]+)$#https://api.github.com/repos/\1/\2/contents/\4?ref=\3#')"
if { curl -fsSL --max-time 20 -H 'Accept: application/vnd.github.raw' ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} "$API" -o "$T/live.json" 2>/dev/null \
     || curl -fsSL --max-time 20 "$URL" -o "$T/live.json" 2>/dev/null; } && jq -e . "$T/live.json" >/dev/null 2>&1; then
  cmp -s "$T/live.json" "$SOT" && ok "S1b copy = $URL" || bad "S1b repos.sot.json DRIFTED from $URL (run git-repos-master ./clone.sh --sync)"
else
  echo "INFO S1b $URL not reachable from here; live comparison not made"
fi

# S2 fleet manifest vs registry
out=$(jq -r --slurpfile s "$SOT" '.fleet.repos[] as $f
  | ($s[0].repos[] | select('"$GH"' == $f.github)) as $r
  | select(($r.status // "") == "pending_creation" or (($r.private // false) != ($f.private // false)))
  | "\($f.dir): registry says status=\($r.status // "-") private=\($r.private // false), fleet says private=\($f.private // false)"' "$M")
[ -z "$out" ] && ok "S2a fleet repos agree with the registry (created, same visibility)" || { bad "S2a fleet/registry disagree"; echo "$out" | sed 's/^/    /'; }
out=$(jq -r --slurpfile s "$SOT" '[$s[0].repos[]|'"$GH"'] as $g | .fleet.repos[] | select(.github as $x | ($g|index($x))==null) | .dir + " (" + .github + ")"' "$M")
[ -z "$out" ] && ok "S2b every fleet repo is in the registry" || { bad "S2b fleet repo not in the registry: $out"; }

# S3 pending vs reality
pend=$(jq -r '.repos[]|select(.status=="pending_creation")|'"$GH" "$SOT")
[ -n "$pend" ] && ok "S3a the registry declares pending_creation repos: $(echo $pend)" || ok "S3a no pending_creation repo declared (all registered repos exist)"
for p in cloud-webapps cloud-me-containers; do jq -e --arg p "$p" '[.repos[].name]|index($p)' "$SOT" >/dev/null 2>&1 || bad "S3b $p must stay registered (pending_creation until it exists, then plain)"; done
bad3=""
for p in $pend; do
  jq -e --arg p "$p" '[.repos[].name]|index($p)' "$INV" >/dev/null 2>&1 && bad3="$bad3 $p(on GitHub: drop its status)"
  jq -e --arg p "$p" '[.fleet.repos[].github]|index($p)' "$M" >/dev/null 2>&1 && bad3="$bad3 $p(in the fleet manifest while pending)"
done
[ -z "$bad3" ] && ok "S3c no pending repo is on GitHub or in the fleet manifest" || bad "S3c pending repos misused:$bad3"

# S4/S5 inventory vs registry
out=$(jq -r --slurpfile s "$SOT" '([$s[0].repos[]|'"$GH"'] + [$s[0].unregistered_ok[].name]) as $known | .repos[] | select(.fork|not) | .name as $n | select(($known|index($n))==null) | $n' "$INV")
[ -z "$out" ] && ok "S4 every GitHub repo is registered or in unregistered_ok" || bad "S4 GitHub repos nobody registered (add to git-repos-master repos.json): $(echo $out)"
out=$(jq -r --slurpfile s "$SOT" '[.repos[].name] as $inv | $s[0].repos[] | select((.status//"")!="pending_creation") | '"$GH"' as $g | select(($inv|index($g))==null) | $g' "$INV")
[ -z "$out" ] && ok "S5a every live registry repo exists on GitHub" || bad "S5a registry repos missing from the GitHub inventory: $(echo $out)"
old=$(jq -r '(.renames // [])[].from, (.repos[].renamed_from // [])[]' "$SOT" | sort -u)
used=""; for o in $old; do jq -e --arg o "$o" '[.fleet.repos[].github]|index($o)' "$M" >/dev/null 2>&1 && used="$used $o"; done
[ -z "$used" ] && ok "S5b no fleet entry still uses a renamed-away name" || bad "S5b fleet manifest uses old name(s):$used"

# S6 mutation: the guard must bite
jq '.repos |= map(select(.name != "cloud-infra"))' "$SOT" > "$T/mut.json"
out=$(jq -r --slurpfile s "$T/mut.json" '[$s[0].repos[]|'"$GH"'] as $g | .fleet.repos[] | select(.github as $x | ($g|index($x))==null) | .dir' "$M")
[ -n "$out" ] && ok "S6 dropping a repo from the registry is caught" || bad "S6 guard does not bite"

echo "repos-sot: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
