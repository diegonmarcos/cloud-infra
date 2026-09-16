#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_ship_latest_monotonic.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ Phase 51 — :latest never moves backwards                                 ║
# ╚══════════════════════════════════════════════════════════════════════════╝
#
# The hazard (agent V, #358): two Ship runs for the SAME image, in flight from
# different commits, both overwrite :latest. Last to FINISH wins, regardless of
# which commit is newer. When the older one lands second, :latest reverts to a
# tree without the newer fix and BOTH runs go green.
#
# Both impure operations of the guard are injected, so this needs neither a
# registry nor a git repository:
#   MONOTONIC_DIGEST_CMD  <ref>            -> digest(s), one per line
#   MONOTONIC_REVLIST_CMD <ours> <branch>  -> commits newer than <ours>
#
# The load-bearing case is 2. Case 1 is the one a weaker guard also passes.

set -uo pipefail

REPO_ROOT="${CLOUD_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
GUARD="${MONOTONIC_GUARD_OVERRIDE:-$REPO_ROOT/1_cicd/src/scripts/cloud-ship-latest-monotonic.sh}"
[ -f "$GUARD" ] || { echo "guard not found: $GUARD"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1: expected '$3', got '$2'"; fail=$((fail+1)); fi; }
ck_has() { case "$2" in *"$3"*) echo "  ok   $1"; pass=$((pass+1));; *) echo "  FAIL $1: output did not contain '$3'"; fail=$((fail+1));; esac; }

IMAGE="ghcr.io/diegonmarcos/cloud-data-reports"
NEW_SHA="2489897ffffffffffffffffffffffffffffffff"   # the newer commit
OLD_SHA="1e87f8d1000000000000000000000000000000f"   # the older commit
D_NEW="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
D_OLD="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# ── Seams ────────────────────────────────────────────────────────────────
# LATEST_IS      — what :latest currently resolves to ("" = no :latest yet)
# TAGGED         — "<short> <digest>" lines: which commit tags exist
# NEWER_COMMITS  — what rev-list <ours>..<branch> answers
cat > "$WORK/digest" <<'STUB'
#!/usr/bin/env bash
ref="$1"; tag="${ref##*:}"
if [ "$tag" = "latest" ]; then
  [ -n "${LATEST_IS:-}" ] && echo "$LATEST_IS"
  exit 0
fi
printf '%s\n' "${TAGGED:-}" | while read -r t d; do
  [ "$t" = "$tag" ] && echo "$d"
done
exit 0
STUB
cat > "$WORK/revlist" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${NEWER_COMMITS:-}" | grep -v '^$' || true
STUB
chmod +x "$WORK/digest" "$WORK/revlist"

run_guard() {
  MONOTONIC_DIGEST_CMD="$WORK/digest" MONOTONIC_REVLIST_CMD="$WORK/revlist" \
  MONOTONIC_TAG_PREFIX="${MONOTONIC_TAG_PREFIX:-}" \
    bash "$GUARD" "$IMAGE" "$1" "$WORK" "origin/main" 2>&1
  echo "RC=$?"
}

echo "── case 1: we ARE the tip — nothing newer exists → publish"
out="$(LATEST_IS="$D_OLD" TAGGED="" NEWER_COMMITS="" run_guard "$NEW_SHA")"
ck_has "tip publish is allowed"            "$out" "RC=0"
ck_has "and says why"                       "$out" "we are the tip"

echo "── case 2: THE RACE — :latest already holds a NEWER commit's image → REFUSE"
# This is V's pair: we are the OLD run, landing second. :latest was set by the
# NEW commit. Publishing would revert it.
out="$(LATEST_IS="$D_NEW" TAGGED="${NEW_SHA:0:7} $D_NEW" NEWER_COMMITS="$NEW_SHA" run_guard "$OLD_SHA")"
ck_has "a backwards move is REFUSED"        "$out" "RC=3"
ck_has "refusal names the descendant commit" "$out" "$NEW_SHA"
ck_has "refusal is an ::error::, not a note" "$out" "::error::"
ck_has "refusal says nothing was pushed"     "$out" "Nothing was pushed"

echo "── case 3: a newer commit EXISTS but has not published — we still publish"
# The newer run is still building. :latest is whatever came before. Refusing
# here would wedge the pipeline on every ordinary overlapping build.
out="$(LATEST_IS="$D_OLD" TAGGED="${NEW_SHA:0:7} $D_NEW" NEWER_COMMITS="$NEW_SHA" run_guard "$OLD_SHA")"
ck_has "unpublished newer commit does not block" "$out" "RC=0"
ck_has "and says so"                             "$out" "publishing is forward"

echo "── case 4: first publish — no :latest at all → publish, never refuse"
out="$(LATEST_IS="" TAGGED="" NEWER_COMMITS="$NEW_SHA" run_guard "$OLD_SHA")"
ck_has "first publish is allowed"           "$out" "RC=0"
ck_has "and names the reason"               "$out" "first publish"

echo "── case 5: the guard is not fooled by an EQUAL digest from our own tag"
# Re-running the same commit must not read as "someone newer published".
out="$(LATEST_IS="$D_OLD" TAGGED="${OLD_SHA:0:7} $D_OLD" NEWER_COMMITS="" run_guard "$OLD_SHA")"
ck_has "republishing the same commit is allowed" "$out" "RC=0"

echo "── case 6: the SOURCE-commit tag prefix is honoured"
# ship-reports.yml tags `:<sha>` with CLOUD-INFRA's commit, while the image's
# content comes from cloud-u-containers. Ordering therefore lives on
# `:src-<sha>`. A guard that looked only at the bare short sha would find no
# tag, take the "not published yet" branch, and never fire — passing every
# other case in this file while protecting nothing. Assert the prefix reaches
# the lookup.
out="$(LATEST_IS="$D_NEW" TAGGED="src-${NEW_SHA:0:7} $D_NEW" NEWER_COMMITS="$NEW_SHA" \
       MONOTONIC_TAG_PREFIX="src-" run_guard "$OLD_SHA")"
ck_has "prefixed source tag is found and REFUSED" "$out" "RC=3"

# And the negative: the same data WITHOUT the prefix must not refuse, which is
# what proves the prefix is doing the work rather than the digest alone.
out="$(LATEST_IS="$D_NEW" TAGGED="src-${NEW_SHA:0:7} $D_NEW" NEWER_COMMITS="$NEW_SHA" \
       run_guard "$OLD_SHA")"
ck_has "without the prefix the same tag is not found" "$out" "RC=0"

echo "── case 7: a MULTI-ARCH tag is reported as its whole digest set"
# The resolver emits the index digest AND every per-arch child. The first
# version of the guard reduced that with `sort -u | head -n1`, which returns
# whichever digest sorts first — a CHILD, not the index — and then printed it
# as though it were what :latest points at. Caught in the guard's own first
# live CI run (35047596807), where it announced a child of the real index.
# The equality test survived that (both sides picked the same representative),
# so only the REPORTED value was wrong — which is exactly the kind of defect
# that destroys trust in a guard on the day it finally refuses.
IDX="sha256:9e0c1f4e00000000000000000000000000000000000000000000000000000000"
KID1="sha256:0253c34400000000000000000000000000000000000000000000000000000000"
KID2="sha256:3cae861f00000000000000000000000000000000000000000000000000000000"
MULTI="$IDX
$KID1
$KID2"
out="$(LATEST_IS="$MULTI" TAGGED="" NEWER_COMMITS="" run_guard "$NEW_SHA")"
ck_has "the index digest is reported"              "$out" "$IDX"
ck_has "and so is each child (the set, not a pick)" "$out" "$KID1"
ck_has "and the second child too"                   "$out" "$KID2"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
