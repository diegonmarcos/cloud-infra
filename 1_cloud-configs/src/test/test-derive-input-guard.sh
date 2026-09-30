#!/usr/bin/env bash
# test-derive-input-guard — the derive must refuse to run on a missing input set
# and refuse to write a consolidated file that loses services undeclared.
#
# Runs on a SCRATCH copy of this repo's working tree plus a scratch copy of
# cloud-u-containers (never a symlink: consolidate writes materialized copies
# into a_solutions/*/src/, and a link would rewrite the shared checkout).
#
#   1. a_solutions absent     → consolidate, derive, link-builds all exit != 0, tree untouched
#   2. a_solutions empty      → consolidate exits != 0, tree untouched
#   3. full a_solutions       → consolidate exits 0 (control: the guard is not always-red)
#   4. 3 services deleted     → consolidate exits != 0 ("collapse"), consolidated untouched
#   5. same 3 in z_archive/   → consolidate exits 0, service count drops by exactly 3
#
# Needs cloud-u-containers: $CONTAINERS_SRC, else ../cloud-u-containers beside
# this repo. Absent → FAIL, not skip: a guard test that skips is a hollow green.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SRC="${CONTAINERS_SRC:-$(dirname "$ROOT")/cloud-u-containers}"
[ -d "$SRC/.git" ] || [ -f "$SRC/.git" ] || { echo "FAIL: no cloud-u-containers checkout at $SRC"; exit 1; }
export PATH="$ROOT/node_modules/.bin:$PATH"

T=$(mktemp -d); trap 'rm -rf "$T" "$T.log" "$T.cuc.tar"' EXIT
setup() {
  set -e
  (cd "$ROOT" && git ls-files -z --cached --others --exclude-standard | grep -zv '^I_cloud/' | tar --null -T - -cf -) | tar -xf - -C "$T"
  ln -s "$ROOT/node_modules" "$T/node_modules"
  git -C "$T" init -q && git -C "$T" add -A && git -C "$T" -c user.name=t -c user.email=t@t commit -qm base
  git -C "$SRC" archive HEAD > "$T.cuc.tar"
  [ -f "$T/1_cloud-configs/build.sh" ] && [ -f "$T/1_cloud-configs/dist/_cloud-data-consolidated.json" ]
}
# Setup failing must be a FAIL: every "refused" case below would otherwise pass
# on a missing build.sh.
( setup ) || { echo "FAIL: scratch setup did not complete"; exit 1; }
fresh_inputs() { rm -rf "$T/a_solutions"; mkdir "$T/a_solutions"; tar -xf "$T.cuc.tar" -C "$T/a_solutions"; }

fail=0
ok()  { echo "  PASS $1"; }
bad() { echo "  FAIL $1"; fail=1; }
cfg() { bash "$T/1_cloud-configs/build.sh" "$@" >"$T.log" 2>&1; }
clean() { [ -z "$(git -C "$T" status --porcelain -- . ':!a_solutions')" ]; }
CONS="$T/1_cloud-configs/dist/_cloud-data-consolidated.json"
count() { jq '.services | length' "$CONS"; }
PREV=$(count)

echo "[1] a_solutions absent"
for step in consolidate derive link-builds; do
  if cfg "$step"; then bad "$step exited 0 with no inputs"
  elif ! grep -q "declared input set" "$T.log"; then bad "$step failed, but not on the input guard: $(grep -m1 -i error "$T.log")"
  elif ! clean; then bad "$step failed but wrote: $(git -C "$T" status --porcelain | head -3 | tr '\n' ' ')"
  else ok "$step refused, tree untouched"; fi
  git -C "$T" checkout -q -- . ; git -C "$T" clean -qfd -e a_solutions
done

echo "[2] a_solutions empty"
mkdir "$T/a_solutions"
if cfg consolidate; then bad "consolidate exited 0 on an empty input set"
elif ! grep -q "declared input set" "$T.log"; then bad "failed, but not on the input guard: $(grep -m1 -i error "$T.log")"
elif ! clean; then bad "consolidate failed but wrote"
else ok "consolidate refused, tree untouched"; fi

echo "[3] full a_solutions (control)"
fresh_inputs
if cfg consolidate && [ "$(count)" -eq "$PREV" ]; then ok "consolidate green, $PREV services"
else bad "consolidate on the real fleet: rc/count wrong ($(count) vs $PREV)"; tail -5 "$T.log"; fi
git -C "$T" checkout -q -- 1_cloud-configs/dist/

# Three enabled services that do not own the wg-public SoT.
VICTIMS=$(jq -r '.services | to_entries[] | select(.value.folder != "infra-net_wireguard-public") | .value.folder' "$CONS" \
  | while read -r f; do [ -f "$T/a_solutions/$f/build.json" ] && echo "$f"; done | head -3)

echo "[4] undeclared removal of: $(echo $VICTIMS)"
for f in $VICTIMS; do rm -rf "$T/a_solutions/$f"; done
if cfg consolidate; then bad "consolidate exited 0 after losing 3 services undeclared"
elif ! grep -q collapse "$T.log"; then bad "failed, but not on the collapse guard: $(tail -2 "$T.log")"
elif ! clean; then bad "collapse refused but consolidated was written"
else ok "collapse refused, consolidated untouched"; fi

echo "[5] same 3 retired via z_archive/"
fresh_inputs
for f in $VICTIMS; do mv "$T/a_solutions/$f" "$T/a_solutions/z_archive/$f.t"; done
if cfg consolidate && [ "$(count)" -eq $((PREV - 3)) ]; then ok "declared removal accepted, $PREV -> $(count)"
else bad "declared removal: rc/count wrong ($(count), expected $((PREV - 3)))"; tail -5 "$T.log"; fi

[ "$fail" -eq 0 ] && echo "test-derive-input-guard: all passed" || echo "test-derive-input-guard: FAILED"
exit "$fail"
