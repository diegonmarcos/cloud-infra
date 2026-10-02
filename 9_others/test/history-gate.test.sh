#!/usr/bin/env bash
# Tester for 0_apps/src/githooks/history-gate (#760): history that a secret
# purge removed must never be published again by a stale clone.
#
# Builds a throwaway repo standing in for "old history" and "new history" and
# runs the REAL gate against it, in both CLI and pre-push mode, then checks the
# real marker list is well-formed and does not flag this checkout's own HEAD.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT/0_apps/src/githooks/history-gate"
LIST="$ROOT/0_apps/src/githooks/purged-history"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASSES=0; FAILS=0
ok()  { PASSES=$((PASSES+1)); echo "  ok   $1"; }
bad() { FAILS=$((FAILS+1));  echo "  FAIL $1"; }

g() { git -C "$TMP/r" -c user.name=t -c user.email=t@invalid -c commit.gpgsign=false "$@"; }
git init -q -b main "$TMP/r"
c() { echo "$1" > "$TMP/r/$1"; g add "$1"; g commit -q -m "$1"; g rev-parse HEAD; }
BASE=$(c base)
g checkout -q -b old; PURGED=$(c leaked); OLDTIP=$(c old-work)     # the removed history
g checkout -q main; NEWTIP=$(c rewritten)                          # what replaced it
printf '# fixture\n%s fixture old-history-root\n' "$PURGED" > "$TMP/list"
run() { (cd "$TMP/r" && HISTORY_GATE_LIST="$TMP/list" sh "$GATE" "$@"); }

run "$NEWTIP" 2>/dev/null && ok "clean new history passes" || bad "clean new history refused"
run "$OLDTIP" 2>/dev/null; [ $? = 1 ] && ok "old tip refused (exit 1)" || bad "old tip not refused"
run "$PURGED" 2>/dev/null; [ $? = 1 ] && ok "the marker itself refused" || bad "marker commit not refused"

# The real failure mode: a stale clone MERGES the new main instead of resetting.
g merge -q --no-edit "$OLDTIP" -m "stale merge" 2>/dev/null; MERGE=$(g rev-parse HEAD)
out=$(run "$MERGE" 2>&1); rc=$?
[ $rc = 1 ] && ok "merge of old history into new main refused" || bad "stale merge passed (rc=$rc)"
grep -q "contains purged commit $PURGED" <<<"$out" && ok "names the purged commit" || bad "marker not named"
g reset -q --hard "$NEWTIP"

Z=0000000000000000000000000000000000000000
printf 'refs/heads/main %s refs/heads/main %s\n' "$NEWTIP" "$BASE" | run --pre-push 2>/dev/null \
    && ok "pre-push: clean push passes" || bad "pre-push: clean push refused"
printf 'refs/heads/main %s refs/heads/main %s\n' "$MERGE" "$NEWTIP" | run --pre-push 2>/dev/null; [ $? = 1 ] \
    && ok "pre-push: stale merge refused" || bad "pre-push: stale merge pushed"
printf '(delete) %s refs/heads/x %s\n' "$Z" "$OLDTIP" | run --pre-push 2>/dev/null \
    && ok "pre-push: a branch delete is not inspected" || bad "pre-push: delete refused"

# A marker from ANOTHER repo (object absent here) is skipped, not an error.
printf '%s\n%s other-repo\n' "$PURGED" "$(printf 'f%.0s' $(seq 40))" > "$TMP/list2"
(cd "$TMP/r" && HISTORY_GATE_LIST="$TMP/list2" sh "$GATE" "$NEWTIP") 2>/dev/null \
    && ok "absent marker object is skipped" || bad "absent marker breaks the gate"

# Fail closed on a broken list: an empty or malformed one must not mean "clean".
printf '# nothing\n' > "$TMP/empty"
(cd "$TMP/r" && HISTORY_GATE_LIST="$TMP/empty" sh "$GATE" "$NEWTIP") 2>/dev/null; [ $? = 2 ] \
    && ok "empty list fails closed (exit 2)" || bad "empty list reported clean"
printf 'abc123 short\n' > "$TMP/short"
(cd "$TMP/r" && HISTORY_GATE_LIST="$TMP/short" sh "$GATE" "$NEWTIP") 2>/dev/null; [ $? = 2 ] \
    && ok "abbreviated SHA rejected (exit 2)" || bad "abbreviated SHA accepted"

# The real list: well-formed, and this checkout's main is not purged history.
(cd "$ROOT" && sh "$GATE" HEAD) && ok "real list: this checkout's HEAD passes" || bad "real list flags HEAD (or is malformed)"

echo "history-gate.test: $PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
