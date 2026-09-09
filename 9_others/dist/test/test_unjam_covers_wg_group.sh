#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_unjam_covers_wg_group.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 46 tester — unjam covers every ship-wg-runner workflow      ║
# ║                                                                   ║
# ║   Every WG-holding job shares ONE concurrency group               ║
# ║   (ship-wg-runner) because the fleet has ONE gha-runner WG        ║
# ║   identity, 10.0.0.200. The cost of that is a wedge in ANY of     ║
# ║   them blocking every deploy fleet-wide, so unjam-ship.yml is     ║
# ║   the safety valve — and it is only a valve if it knows about     ║
# ║   all of them. On 2026-09-06 a scheduled cgc-db run hung for      ║
# ║   three hours holding the group while the unjammer, which knew    ║
# ║   only ship.yml, could not touch it.                              ║
# ║                                                                   ║
# ║   Asserts: the set of workflows declaring `group: ship-wg-runner` ║
# ║   equals WG_WORKFLOWS in unjam-ship.yml, in both directions.      ║
# ║                                                                   ║
# ║ Usage: bash 9_others/test/test_unjam_covers_wg_group.sh           ║
# ╚══════════════════════════════════════════════════════════════════╝
set -uo pipefail

REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
CICD_SRC="$REPO_ROOT/1_cicd/src/cicd"
UNJAM="$CICD_SRC/unjam-ship.yml"
FAIL=0

pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── Phase 46: unjam-ship.yml covers every ship-wg-runner workflow ──"

[ -f "$UNJAM" ] || { fail "missing $UNJAM"; exit 1; }

# 1. Workflows whose RUNS can hold the group. Anchored to a real YAML mapping
#    line: a prose mention inside a `#` comment (unjam-ship.yml's own header
#    explains the group, and matched a loose grep on the first run of this
#    test) is not a declaration.
#
#    A declaration in a REUSABLE workflow resolves to that workflow's CALLERS,
#    not to itself. cgc-db-index.yml declares the group on its restore-all job,
#    but it is workflow_call-only: it has no runs of its own, its jobs execute
#    under the caller's run id, and /actions/workflows/cgc-db-index.yml/runs is
#    empty forever. Listing it in WG_WORKFLOWS would be a dead entry AND would
#    displace cgc-db.yml, which is the id that actually has to be cancelled —
#    the precise invisible hole this test exists to prevent.
resolve_holders() {
  _f="$1"; _b=$(basename "$_f")
  if grep -qE '^[[:space:]]*workflow_call:[[:space:]]*$' "$_f"; then
    # Reusable: emit every workflow that calls it. If nothing calls it, emit
    # nothing — an uncallable workflow cannot hold the group.
    grep -lE "uses:[[:space:]]*\./\.github/workflows/$_b[[:space:]]*$" \
      "$CICD_SRC"/*.yml 2>/dev/null | xargs -r -n1 basename
  else
    printf '%s\n' "$_b"
  fi
}

DECLARED=$(for f in $(grep -lE '^[[:space:]]*group:[[:space:]]*ship-wg-runner[[:space:]]*$' \
  "$CICD_SRC"/*.yml 2>/dev/null); do resolve_holders "$f"; done | sort -u)

# 2. The list the unjammer iterates. Take the WG_WORKFLOWS assignment only.
LISTED=$(sed -n 's/^ *WG_WORKFLOWS="\(.*\)"$/\1/p' "$UNJAM" \
  | tr ' ' '\n' | grep -v '^$' | sort -u)

if [ -z "$LISTED" ]; then
  fail "WG_WORKFLOWS not found in unjam-ship.yml (expected a single-line assignment)"
  echo ""
  echo "Phase 46 unjam WG coverage: FAIL"
  exit 1
fi

# unjam-ship.yml itself never declares the group; every other member must.
MISSING=$(comm -23 <(printf '%s\n' "$DECLARED") <(printf '%s\n' "$LISTED"))
EXTRA=$(comm -13 <(printf '%s\n' "$DECLARED") <(printf '%s\n' "$LISTED"))

if [ -n "$MISSING" ]; then
  for w in $MISSING; do
    fail "$w declares group ship-wg-runner but unjam-ship.yml's WG_WORKFLOWS does not list it — a wedge there would be unclearable"
  done
else
  pass "every workflow declaring ship-wg-runner is in WG_WORKFLOWS ($(printf '%s\n' "$DECLARED" | wc -l | tr -d ' ') workflows)"
fi

if [ -n "$EXTRA" ]; then
  for w in $EXTRA; do
    if [ -f "$CICD_SRC/$w" ]; then
      fail "WG_WORKFLOWS lists $w but it no longer declares group ship-wg-runner — stale entry"
    else
      fail "WG_WORKFLOWS lists $w but $CICD_SRC/$w does not exist — stale entry"
    fi
  done
else
  pass "WG_WORKFLOWS carries no stale entries"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "══════════════════════════════════════════════"
  echo "Phase 46 unjam WG coverage: PASS"
  echo "══════════════════════════════════════════════"
else
  echo "══════════════════════════════════════════════"
  echo "Phase 46 unjam WG coverage: FAIL"
  echo "══════════════════════════════════════════════"
fi
exit "$FAIL"
