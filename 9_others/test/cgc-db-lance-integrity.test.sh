#!/usr/bin/env bash
# Tester for the check that ends the cgc index's silent-corruption era (#213).
#
# THE FAILURE IT GUARDS: a lance table is data fragments + a chain of manifests,
# each manifest naming the fragments that version needs. cloud-u-android's
# document_blocks.lance had 7352 manifests and a data/ directory containing ZERO
# files, every manifest naming the same absent fragment
# (00111111010110100011100111cda449a497482bee18280916.lance). Every octocode
# query against that repo died with `lance error: Not found`, and because
# octocode opens its tables together it killed the whole query -- a torn
# document_blocks made cloud-u-android unable to answer a CODE question too.
#
# WHY IT SURVIVED GREEN RUNS: the damage was re-published every cycle. The
# per-repo job layers the repo's prior GHCR checkpoint in as its incremental
# base; octocode's change-gate sees the table present and never rewrites it;
# package pushes it straight back; restore-all copies it faithfully to oci-apps.
# Nothing ever asked whether a manifest's fragments actually existed. So this
# tests the ONE property that breaks that loop: a manifest naming an absent
# fragment must be REPORTED, and a healthy home must not be.
#
# The function under test is extracted from update.sh BY NAME, so this drives the
# real production code, not a re-implementation of it (a re-implementation is how
# cgc-db-gate.test.sh passed while the path it mirrored was wrong).
set -uo pipefail

REPO_ROOT="$(_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
UPD_SH="$REPO_ROOT/1_cicd/src/ops/cloud-cgc-db-update.sh"
[ -f "$UPD_SH" ] || { echo "::error::cloud-cgc-db-update.sh not found at $UPD_SH"; exit 1; }

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }

# Extract lance_dangling_tables() verbatim. Fail loudly if it is gone or renamed --
# a tester that silently tests nothing is the thing this repo keeps getting burned by.
FN="$(awk '/^lance_dangling_tables\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$UPD_SH")"
case "$FN" in
  *"lance_dangling_tables()"*) : ;;
  *) echo "::error::could not extract lance_dangling_tables() from $UPD_SH"; exit 1 ;;
esac
eval "$FN"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# A lance _versions entry is named u64::MAX - version, so the lexicographically
# FIRST filename is the NEWEST version -- that is the one a reader opens.
# 18446744073709551614 = v1, ...613 = v2 (newer, sorts first).
V_OLD=18446744073709551614.manifest
V_NEW=18446744073709551613.manifest

# Write a manifest that names $2. The leading \070 ('8') is the protobuf
# length byte that precedes the string in a real manifest -- it is itself a hex
# character, which is exactly why the check must match by suffix, not equality.
mkmanifest() { printf 'LANC\070%s\000\001' "$2" > "$1"; }

mktable() { # $1=dir $2=newest-ref $3=oldest-ref $4...=fragments to actually create
  local d="$1" newref="$2" oldref="$3"; shift 3
  mkdir -p "$d/_versions" "$d/data"
  mkmanifest "$d/_versions/$V_NEW" "$newref"
  mkmanifest "$d/_versions/$V_OLD" "$oldref"
  local f; for f in "$@"; do printf 'DATA' > "$d/data/$f"; done
}

A=00111111010110100011100111cda449a497482bee18280916.lance
B=000100101110110100001110401d404e3291dbb61535e7dfb5.lance

H="$WORK/home"

# 1. the production shape: manifests present, data/ EMPTY.
mktable "$H/repo1/storage/document_blocks.lance" "$A" "$A"
# 2. healthy: newest manifest's fragment is on disk.
mktable "$H/repo1/storage/code_blocks.lance" "$B" "$B" "$B"
# 3. genuinely-empty table (no fragment refs at all) -- must NOT be flagged, or
#    every fresh repo would trigger a needless full re-index.
mkdir -p "$H/repo1/storage/text_blocks.lance/_versions" "$H/repo1/storage/text_blocks.lance/data"
printf 'LANC\000\001' > "$H/repo1/storage/text_blocks.lance/_versions/$V_NEW"
# 4. root state must never be walked as a project dir.
mkdir -p "$H/fastembed"

OUT="$(lance_dangling_tables "$H")"

case "$OUT" in
  *"repo1/storage/document_blocks.lance"*) ok "flags the real shape: manifests + empty data/" ;;
  *) bad "did NOT flag document_blocks with an empty data/ -- this is the exact production corruption; got: [$OUT]" ;;
esac
case "$OUT" in
  *"code_blocks"*) bad "flagged a HEALTHY table (fragment present on disk)" ;;
  *) ok "leaves a healthy table alone" ;;
esac
case "$OUT" in
  *"text_blocks"*) bad "flagged a table whose manifest references no fragments (legitimately empty)" ;;
  *) ok "leaves a legitimately-empty table alone" ;;
esac

# 5. NEWEST manifest is the one that matters, in BOTH directions. Without this a
#    check that scanned any/all manifests would look correct on the tests above.
H2="$WORK/newest"
mktable "$H2/r/storage/t.lance" "$A" "$B" "$B"   # newest names A (absent), old names B (present)
case "$(lance_dangling_tables "$H2")" in
  *"t.lance"*) ok "reads the NEWEST manifest (flags when only the newest is broken)" ;;
  *) bad "missed a break that exists only in the newest manifest" ;;
esac
H3="$WORK/newest-ok"
mktable "$H3/r/storage/t.lance" "$B" "$A" "$B"   # newest names B (present), old names A (absent)
case "$(lance_dangling_tables "$H3")" in
  *"t.lance"*) bad "flagged a table whose NEWEST manifest is fine (only a superseded version was broken)" ;;
  *) ok "ignores a break in a superseded version" ;;
esac

# 6. A table with no _versions/ at all is not a lance table -- must not be flagged.
H4="$WORK/noversions"; mkdir -p "$H4/r/storage/t.lance/data"
case "$(lance_dangling_tables "$H4")" in
  "") ok "ignores a directory with no _versions/" ;;
  *)  bad "flagged a dir with no _versions/" ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# 7. THE SECOND COPY. cloud-cgc-db-restore-all.sh is `cat`-ed whole onto the box
#    and run standalone, so it cannot source this function -- it carries its own
#    verbatim copy. A copy that drifts is how cgc-db-gate.test.sh passed while the
#    path it mirrored was wrong, so pin the two as byte-identical and drive the
#    restore-all copy through the SAME cases rather than trusting the read-through.
RA_SH="$REPO_ROOT/1_cicd/src/ops/cloud-cgc-db-restore-all.sh"
[ -f "$RA_SH" ] || { echo "::error::cloud-cgc-db-restore-all.sh not found at $RA_SH"; exit 1; }

FN_RA="$(awk '/^lance_dangling_tables\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$RA_SH")"
case "$FN_RA" in
  *"lance_dangling_tables()"*) ok "restore-all.sh carries a lance_dangling_tables()" ;;
  *) bad "restore-all.sh has NO lance_dangling_tables() -- the staged tree is ungated and a torn GHCR image can wipe a live volume"; FN_RA="" ;;
esac

if [ "$FN_RA" = "$FN" ]; then
  ok "the two copies are byte-identical"
else
  bad "restore-all.sh's copy has DRIFTED from cloud-cgc-db-update.sh's -- one of the two gates is now testing something else"
fi

# Drive the restore-all copy itself, under its own name, through the production
# shape + the healthy control. Identity above makes this redundant ONLY while it
# holds; when it breaks, this is what says which copy went wrong.
if [ -n "$FN_RA" ]; then
  ( eval "$(printf '%s' "$FN_RA" | sed 's/^lance_dangling_tables()/ra_ldt()/')"
    rc=0
    case "$(ra_ldt "$H")" in
      *"repo1/storage/document_blocks.lance"*) ;;
      *) echo "  FAIL: restore-all copy did NOT flag the production shape"; rc=1 ;;
    esac
    case "$(ra_ldt "$H")" in
      *"code_blocks"*) echo "  FAIL: restore-all copy flagged a HEALTHY table"; rc=1 ;;
    esac
    exit $rc
  ) && ok "restore-all copy behaves identically on the production shape" \
    || bad "restore-all copy misbehaved (see FAIL lines above)"
fi

# 8. THE GATE IS WIRED. A function nobody calls is a no-op, and "guards that name
#    their own target" is a repeat failure here -- so assert the CALL SITE exists,
#    that it runs against $STAGING (the tree pulled from GHCR, not the live volume),
#    and that a positive result EXITS NON-ZERO instead of merely warning.
# 8. THE GATE IS WIRED. A function nobody calls is a no-op, and a grep-based check
#    matches its OWN prose once the explanation is committed alongside it -- the
#    comment above the gate quotes `rm -rf /dst/*` verbatim, which is exactly how
#    this assertion first "found" the swap 49 lines ABOVE the swap. So every
#    structural check here searches CODE only, never comment lines.
code_line() { # $1=file $2=literal substring -> line number of first NON-COMMENT match
  awk -v pat="$2" '{ s=$0; sub(/^[[:space:]]+/,"",s); if (s ~ /^#/) next; if (index($0,pat)) { print NR; exit } }' "$1"
}

GATE_LN=$(code_line "$RA_SH" 'lance_dangling_tables "$STAGING"')
SWAP_LN=$(code_line "$RA_SH" 'rm -rf /dst/*')

if [ -n "$GATE_LN" ]; then
  ok "the staged tree is actually gated (call site is real code, line $GATE_LN)"
else
  bad "restore-all.sh never CALLS lance_dangling_tables on \$STAGING outside a comment -- the gate is dead code"
fi

# The refusal must abort, not warn: awk the block from the call to its closing fi.
GATE_BLOCK="$(awk '/_staging_torn=\$\(lance_dangling_tables/{f=1} f{print} f&&/^fi$/{exit}' "$RA_SH")"
case "$GATE_BLOCK" in
  *"exit 1"*) ok "a torn staged tree ABORTS the restore (exit 1), leaving the live volume untouched" ;;
  *) bad "the torn-staging branch does not exit non-zero -- it would log an error and wipe the volume anyway" ;;
esac

# 9. And the gate must sit BEFORE the destructive swap, or it gates nothing.
if [ -n "$GATE_LN" ] && [ -n "$SWAP_LN" ] && [ "$GATE_LN" -lt "$SWAP_LN" ]; then
  ok "the gate runs BEFORE the rm -rf swap (gate@$GATE_LN < swap@$SWAP_LN)"
else
  bad "gate/swap ordering wrong or unlocatable (gate@${GATE_LN:-none} swap@${SWAP_LN:-none}) -- a check after the wipe cannot save the volume"
fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ] || exit 1
