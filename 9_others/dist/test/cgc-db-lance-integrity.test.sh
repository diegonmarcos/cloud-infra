#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/cgc-db-lance-integrity.test.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

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

# 10. AND THE STAGED TREE MUST SURVIVE LONG ENOUGH TO BE GATED. oci-apps' disk
#     watchdog deletes /tmp and /var/tmp files whose atime is older than 2 days
#     as soon as root hits 85%, and `docker cp` stages every file with the
#     image's own (old) timestamps — so a bare `mktemp -d`, i.e. /tmp, had the
#     host deleting fragments out of the staging tree mid-restore while the
#     ~8GB staging was itself what pushed the disk over that threshold. The gate
#     above then correctly refused images that were clean on GHCR. Pin the
#     staging location, or that failure returns silently.
STAGE_LN=$(code_line "$RA_SH" 'STAGING=$(mktemp -d')
STAGE_CODE=$(awk -v n="${STAGE_LN:-0}" 'NR==n' "$RA_SH")
case "$STAGE_CODE" in
  *'mktemp -d "$STAGING_PARENT/'*) ok "staging is created under an explicit parent, not the default temp dir" ;;
  *) bad "restore-all stages via a bare mktemp -d (so /tmp), where the box's disk watchdog deletes staged fragments by atime: [$STAGE_CODE]" ;;
esac

PARENT_CODE=$(awk '/^STAGING_PARENT=/{print; exit}' "$RA_SH")
case "$PARENT_CODE" in
  "") bad "no STAGING_PARENT assignment in restore-all.sh — nothing decides where the staged tree lives" ;;
  *"/tmp"*) bad "the staging parent points at a reaped tmp dir: [$PARENT_CODE]" ;;
  *) ok "the staging parent defaults off /tmp and /var/tmp" ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# 11. THE SWAP ITSELF MUST BE ABLE TO FAIL (#352 defect 2).
#     Everything above gates the STAGED tree, before the swap. None of it can see
#     a swap that corrupts the volume on its way in, and until 2026-09-16 the swap
#     literally could not report one: it ran as
#         sh -c 'rm -rf /dst/*; cp -a /src/. /dst/; chmod 0755 /dst
#                [ -n "$CGC_DB_OWNER" ] && chown -R "$CGC_DB_OWNER" /dst; :'
#     with no `set -e` and a trailing `:` forcing the shell's status to 0. A `cp -a`
#     killed by ENOSPC part-way -- the live risk on a box the script's own
#     STAGING_PARENT comment measures at 76%->85% from this staging tree alone --
#     left a half-written volume, returned 0, and the outer `set -eu` never fired.
#     The run went GREEN and `cgc_octocode_search` threw `lance error: Not found`
#     against a manifest whose fragments had never been copied. The good copy was
#     already gone: `rm -rf /dst/*` runs first.
#
#     These assertions are structural because the failure is structural -- there is
#     no host here with a docker socket to drive a real swap against. They search
#     CODE only (comment lines are skipped by code_line / the block extraction
#     below starts at a code line), for the same reason section 8 does: the prose
#     explaining this fix quotes the broken form verbatim.
SWAP_CODE_LN=$(code_line "$RA_SH" 'CGC_DB_TARGET_VOLUME:/dst')
if [ -n "$SWAP_CODE_LN" ]; then
  # From the docker run's -v line to the end of the swap's failure handler.
  SWAP_BLOCK="$(awk -v n="$SWAP_CODE_LN" 'NR>=n-2 && NR<n+30' "$RA_SH")"
else
  SWAP_BLOCK=""
  bad "cannot locate the volume swap in restore-all.sh -- every check below is blind"
fi

# 11a. The busybox shell must abort on the first failed command.
case "$SWAP_BLOCK" in
  *"sh -ec "*) ok "the swap's busybox shell runs under -e (a failed cp aborts it)" ;;
  *) bad "the swap's busybox shell has no -e: a cp that dies part-way keeps going and the volume is served half-written" ;;
esac

# 11b. THE MASK. A trailing `:` (or `; true`) as the last command pins the status
#      at 0 and makes every check in 11a pointless.
case "$SWAP_BLOCK" in
  *"; :'"*|*"; true'"*) bad "the swap still ends in a status-masking ': the busybox shell reports 0 no matter what happened, so the outer set -eu can never see a failed swap" ;;
  *) ok "the swap does not mask its own exit status" ;;
esac

# 11c. The chown must be an explicit if. `[ -n "$X" ] && chown` as the LAST command
#      is status-1-when-empty, which is what the `:` was there to hide -- restore
#      the `&&` and someone will "fix" it with a `:` again. This is the same trap
#      the comment at the bottom of restore-all.sh diagnosed on 2026-09-07.
case "$SWAP_BLOCK" in
  *'CGC_DB_OWNER" ] && chown'*) bad "the swap's chown is a trailing [ ... ] && chown, whose status is 1 when CGC_DB_OWNER is empty -- the exact thing that got masked with a ':' last time" ;;
  *) ok "the swap's chown is an explicit if, not a status-leaking &&" ;;
esac

# 11d. And the failure has to be FATAL to the restore, not logged and walked past.
case "$SWAP_BLOCK" in
  *"exit 1"*) ok "a failed swap exits non-zero (the run goes RED instead of green over a torn volume)" ;;
  *) bad "nothing in the swap block exits non-zero -- a failed swap would still reach 'RESTORE COMPLETE'" ;;
esac

# 11e. BEHAVIOURAL, not just structural. Everything in 11a-11d matches text; this
#      EXTRACTS the busybox script the swap actually runs and EXECUTES it, with
#      /src and /dst redirected at scratch dirs, to prove the two properties that
#      matter: a copy that cannot complete makes it exit NON-ZERO, and a copy that
#      completes makes it exit ZERO. The pre-fix fragment returns 0 in both cases
#      -- that is the whole defect, and a text match alone would not have caught a
#      "fix" that kept the `:` somewhere else in the pipeline.
SWAP_SH="$(awk "NR>=$SWAP_CODE_LN" "$RA_SH" \
  | awk '/sh -ec '"'"'/{f=1; sub(/^.*sh -ec '"'"'/,""); } f{print} f&&/'"'"' \|\| \{$/{exit}' \
  | sed "s/' || {\$//")"

if [ -z "$SWAP_SH" ]; then
  bad "could not extract the swap's busybox script -- 11e cannot run (did the sh -ec form change?)"
else
  SB="$WORK/swapbeh"; mkdir -p "$SB/src/proj/storage" "$SB/dst"
  printf 'FRAGMENT' > "$SB/src/proj/storage/a.lance"
  printf 'FRAGMENT' > "$SB/src/proj/storage/b.lance"
  printf 'cfg'      > "$SB/src/config.toml"
  # Same script, /src and /dst pointed at the scratch dirs. CGC_DB_OWNER empty is
  # the case the masking `:` existed to paper over, so test exactly that.
  SWAP_RUN="$(printf '%s' "$SWAP_SH" | sed -e "s#/src#$SB/src#g" -e "s#/dst#$SB/dst#g")"

  # (i) happy path must succeed and must report parity.
  beh_out="$(CGC_DB_OWNER="" sh -ec "$SWAP_RUN" 2>&1)"; beh_rc=$?
  if [ "$beh_rc" -eq 0 ]; then
    ok "swap fragment exits 0 on a complete copy (CGC_DB_OWNER empty)"
  else
    bad "swap fragment failed a HEALTHY copy (rc=$beh_rc): $beh_out -- this would break every restore"
  fi
  case "$beh_out" in
    *"parity OK"*) ok "swap fragment reports the parity it checked" ;;
    *) bad "swap fragment produced no parity line: $beh_out" ;;
  esac

  # (ii) THE DEFECT. Make the destination unwritable so cp cannot complete. The
  #      pre-fix fragment (`sh -c ... ; :`) exits 0 here -- that is precisely how a
  #      restore reported success over a half-copied volume and left agents querying
  #      a manifest whose fragments were never written.
  rm -rf "$SB/dst"; mkdir -p "$SB/dst"; chmod 0500 "$SB/dst"
  beh_out2="$(CGC_DB_OWNER="" sh -ec "$SWAP_RUN" 2>&1)"; beh_rc2=$?
  chmod 0700 "$SB/dst"
  if [ "$beh_rc2" -ne 0 ]; then
    ok "swap fragment exits NON-ZERO when the copy cannot complete (rc=$beh_rc2)"
  else
    bad "swap fragment returned 0 over a copy that could not be written -- the restore will report success over a torn volume, which is #352 defect 2 exactly"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# 12. THE RESTORE MUST VERIFY WHAT IT ACTUALLY WROTE.
#     lance_dangling_tables runs on $STAGING only. Proving the staged tree is clean
#     says nothing about the tree in the volume, and the gap between the two is
#     precisely the swap. The post-restart reindex tail is NOT a substitute and was
#     checked: octocode-export.py opens graphrag_nodes/relationships/git_metadata
#     only, never document_blocks/text_blocks/code_blocks -- the tables that were
#     actually torn in both reported #352 failures -- and its failure is downgraded
#     to a ::warning:: anyway.
case "$SWAP_BLOCK" in
  *"find /src -type f"*|*'find "$STAGING" -type f'*) ok "the swap compares the staged tree against what landed" ;;
  *) bad "nothing re-reads the target after the swap: a fragment missing from the VOLUME (as opposed to from staging) is invisible to every check in this file" ;;
esac

# 12b. Both branches, not just the one this box happens to use. The CI path
#      (cgc-db-index.yml) passes CGC_DB_TARGET_VOLUME and takes the volume branch;
#      the dagu/manual path takes the host-dir branch. A check on one only is how
#      half of a two-branch fix goes unnoticed.
HOST_SWAP_LN=$(code_line "$RA_SH" 'cp -a "$STAGING"/. "$TARGET"/')
if [ -n "$HOST_SWAP_LN" ]; then
  HOST_BLOCK="$(awk -v n="$HOST_SWAP_LN" 'NR>=n && NR<n+20' "$RA_SH")"
  case "$HOST_BLOCK" in
    *'find "$TARGET" -type f'*) ok "the host-dir branch also verifies what it wrote" ;;
    *) bad "the host-dir swap branch writes TARGET and never checks it" ;;
  esac
  case "$HOST_BLOCK" in
    *'CGC_DB_OWNER:-}" ] && chown'*) bad "the host-dir branch still uses a trailing [ ... ] && chown" ;;
    *) ok "the host-dir branch's chown is an explicit if" ;;
  esac
else
  bad "cannot locate the host-dir swap branch in restore-all.sh"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 13. THE THIRD COPY. There are not two of this script, there are three:
#       1_cicd/src/ops/cloud-cgc-db-restore-all.sh                  (CI -> box)
#       1_cicd/dist/scripts/cloud-cgc-db-restore-all.sh             (generated)
#       a_solutions/user-ai_cloud-cgc-pub-mcp/src/cloud-cgc-db-restore-all.sh
#     The third is a DIFFERENT repository (diegonmarcos/cloud-u-containers) and is
#     read at Nix eval time by that service's compose.nix (builtins.readFile) into
#     the db-restore-multi profile, so it is a real execution path, not a stale
#     copy. When the swap fix landed in 1_cicd on 2026-09-16 that copy still had
#     the `sh -c ... ; :` form verbatim -- i.e. fixing one copy leaves the compose
#     path armed with the exact defect. Section 7 pins copies 1 and 2 against
#     drift; nothing pinned the third.
#
#     Scoped to the SWAP REGION on purpose, not whole-file identity: the two files
#     have legitimately diverged elsewhere (~250 diff lines), and a whole-file pin
#     would be red from the day it was written and get deleted rather than fixed.
RA3="$REPO_ROOT/a_solutions/user-ai_cloud-cgc-pub-mcp/src/cloud-cgc-db-restore-all.sh"
swap_region() { # $1=file -> the swap block, both branches
  sed -n '/THE SWAP MUST BE ABLE TO FAIL/,/swap parity OK: \$_dst_n files in \$TARGET/p' "$1"
}
if [ ! -d "$REPO_ROOT/a_solutions" ]; then
  # Neither pass nor fail: this checkout simply does not have the other repo, and
  # counting it as a pass would be the "guard that tests nothing" this file exists
  # to prevent. lint-pipeline.yml always checks it out (actions/checkout with
  # repository: diegonmarcos/cloud-u-containers, path: a_solutions), so the gate is
  # real where it gates.
  echo "  SKIPPED (not counted): a_solutions/ is not checked out here, so the compose copy of restore-all could not be compared. CI always checks it out."
elif [ ! -f "$RA3" ]; then
  bad "a_solutions/ is checked out but $RA3 is gone -- the compose db-restore-multi profile reads that path at Nix eval time"
else
  R1="$(swap_region "$RA_SH")"
  R3="$(swap_region "$RA3")"
  if [ -z "$R1" ]; then
    bad "could not extract the swap region from $RA_SH -- section 13 cannot compare anything"
  elif [ -z "$R3" ]; then
    bad "the compose copy (a_solutions/user-ai_cloud-cgc-pub-mcp/src/cloud-cgc-db-restore-all.sh) has NO fixed swap region: its restore still cannot report a failed copy, so the db-restore-multi path can still wipe a volume and report success"
  elif [ "$R1" = "$R3" ]; then
    ok "the compose copy's swap region is identical to 1_cicd's"
  else
    bad "the compose copy's swap region has DRIFTED from 1_cicd's -- two execution paths, two behaviours, and only one of them is tested above"
  fi
fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ] || exit 1
