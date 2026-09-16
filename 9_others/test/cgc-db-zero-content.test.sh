#!/usr/bin/env bash
# Tester for the zero-content gate that ends the cgc index's SILENT-BLINDNESS era (#352).
#
# THE FAILURE IT GUARDS: a repo can reach the served volume holding a project dir
# that is present, structurally perfect, readable by every existing check -- and
# completely empty. The lance integrity gate asks "is it READABLE?". The
# project-dir count asks "did the right NUMBER of repos arrive?". Neither asks
# whether the repo actually HOLDS anything.
#
# WHY IT SURVIVED GREEN RUNS: octocode does not answer a query against an empty
# store with "not indexed". It answers with twenty confident rows of whatever else
# is in the volume, at noise-floor similarity. A blind repo is therefore
# indistinguishable from a working one at the query surface, and every pipeline
# stage upstream reports success. #352 sat for days against acceptance queries that
# could not pass while every run was green. The real cases: octocode had no Kotlin
# grammar so all ~9,900 .kt files were dropped at the file walk; and an index that
# logged "Indexing complete! 0 of 0 files processed" published a 4.0GB checkpoint.
#
# So this tests the ONE property that breaks that loop, IN BOTH DIRECTIONS: a repo
# with no content blocks must be REPORTED, and a repo that has content must not be.
# A guard proven in only one direction is not proven.
#
# The function under test is extracted from cloud-cgc-db-restore-all.sh BY NAME, so
# this drives the real production code, not a re-implementation of it (a
# re-implementation is how cgc-db-gate.test.sh passed while the path it mirrored
# was wrong).
set -uo pipefail

REPO_ROOT="$(_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
SRC_SH="$REPO_ROOT/1_cicd/src/ops/cloud-cgc-db-restore-all.sh"
DIST_SH="$REPO_ROOT/1_cicd/dist/scripts/cloud-cgc-db-restore-all.sh"
[ -f "$SRC_SH" ] || { echo "::error::cloud-cgc-db-restore-all.sh not found at $SRC_SH"; exit 1; }

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }

# Extract the function AND the table list it reads, verbatim, from $1. Fail loudly
# if either is gone or renamed -- a tester that silently tests nothing is the thing
# this repo keeps getting burned by.
load_fn() {
  local sh="$1" fn tables
  fn="$(awk '/^zero_content_projects\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$sh")"
  case "$fn" in
    *"zero_content_projects()"*) : ;;
    *) echo "::error::could not extract zero_content_projects() from $sh"; exit 1 ;;
  esac
  tables="$(grep -E '^CGC_CONTENT_TABLES=' "$sh" | head -1)"
  [ -n "$tables" ] || { echo "::error::could not extract CGC_CONTENT_TABLES from $sh"; exit 1; }
  eval "$tables"
  eval "$fn"
}
load_fn "$SRC_SH"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# A project dir as the pipeline actually lays it out: <home>/<project_id>/storage/<table>.lance/{_versions,data}.
# Fragment CONTENT is irrelevant here -- the gate asks only whether data/ holds a
# fragment at all, so an empty file is a faithful stand-in for a populated one.
mkproject() { # $1=home $2=project_id $3...=content tables to populate
  local home="$1" id="$2"; shift 2
  local t
  for t in $CGC_CONTENT_TABLES; do mkdir -p "$home/$id/storage/$t.lance/_versions" "$home/$id/storage/$t.lance/data"; done
  for t in "$@"; do : > "$home/$id/storage/$t.lance/data/0000$RANDOM.lance"; done
}

# ── direction 1: a healthy home must go GREEN ──────────────────────────────
H="$WORK/home"
mkdir -p "$H/fastembed" "$H/sentencetransformer"
mkproject "$H" aaa111 code_blocks text_blocks document_blocks
mkproject "$H" bbb222 code_blocks
got="$(zero_content_projects "$H")"
[ -z "$got" ] && ok "a home where every project holds content reports nothing" \
              || bad "healthy home reported blind project(s): $got"

# ── direction 2: remove a repo's content and it must go RED ────────────────
# This is the mutation. Directory structure is left perfectly intact -- only the
# fragments go -- because "present, readable and empty" is the exact shape #352 shipped.
for t in $CGC_CONTENT_TABLES; do rm -f "$H/bbb222/storage/$t.lance/data/"*.lance; done
got="$(zero_content_projects "$H")"
case "$got" in
  *bbb222*) ok "RED: the emptied repo is reported ($(basename "$got"))" ;;
  "")       bad "RED direction: emptied repo was NOT reported -- the gate is a no-op" ;;
  *)        bad "RED direction: reported the wrong project: $got" ;;
esac
[ "$(printf '%s\n' "$got" | grep -c .)" = 1 ] \
  && ok "RED: only the emptied repo is reported, the healthy sibling is not" \
  || bad "RED: expected exactly one blind project, got: $got"
case "$got" in
  */aaa111 | *aaa111*) bad "RED: the populated sibling aaa111 was wrongly reported" ;;
  *) ok "RED: aaa111 (populated) stays out of the report" ;;
esac

# ── direction 3: restore the content and it must go GREEN again ────────────
# The point of asserting the return trip: a gate that latches red once and never
# recovers is just as broken as one that never fires, and it would be "fixed" by
# someone deleting it.
: > "$H/bbb222/storage/code_blocks.lance/data/00007777.lance"
got="$(zero_content_projects "$H")"
[ -z "$got" ] && ok "GREEN again: restoring one fragment clears the repo" \
              || bad "gate latched red after content was restored: $got"

# ── the boundary cases that decide whether this is a real check ────────────
# docs-only must NOT fail: the gate is all-three-empty, not any-empty.
D="$WORK/docsonly"; mkproject "$D" ccc333 document_blocks
[ -z "$(zero_content_projects "$D")" ] \
  && ok "a docs-only repo is not failed for holding no code_blocks" \
  || bad "docs-only repo wrongly reported blind"

# Root state is not project data and legitimately has no content tables.
R="$WORK/rootonly"; mkdir -p "$R/fastembed/storage" "$R/sentencetransformer/storage"
[ -z "$(zero_content_projects "$R")" ] \
  && ok "fastembed/ and sentencetransformer/ are never reported as blind repos" \
  || bad "root-state dirs wrongly reported as blind repos"

# A table dir that exists with an EMPTY data/ is the #352 shape, not a healthy repo.
E="$WORK/emptytables"; mkproject "$E" ddd444
case "$(zero_content_projects "$E")" in
  *ddd444*) ok "a project whose tables exist but hold zero fragments is reported" ;;
  *)        bad "a structurally-perfect empty project was NOT reported" ;;
esac

# A project with no storage/ at all must not read as clean (fail closed).
N="$WORK/nostorage"; mkdir -p "$N/eee555"
case "$(zero_content_projects "$N")" in
  *eee555*) ok "a project with no storage/ at all is reported (fails closed)" ;;
  *)        bad "a project with no storage/ read as clean -- the gate fails OPEN" ;;
esac

# ── the gate must be WIRED, not merely defined ─────────────────────────────
# A function nobody calls is the exact way this fleet's checks rot into decoration.
grep -q 'zero_content_projects "\$STAGING"' "$SRC_SH" \
  && ok "the gate is actually invoked against the staged tree" \
  || bad "zero_content_projects() is defined but never called on \$STAGING"
awk '/_staging_blind=\$\(zero_content_projects/,/^fi$/' "$SRC_SH" | grep -q 'exit 1' \
  && ok "a blind repo EXITS NON-ZERO -- it refuses the swap rather than warning" \
  || bad "the blind-repo branch does not exit 1; it would warn and swap anyway"
# It must refuse BEFORE the destructive swap, or it guards nothing.
gate_line=$(grep -n '_staging_blind=$(zero_content_projects' "$SRC_SH" | cut -d: -f1)
swap_line=$(grep -n '^# ── 4) swap' "$SRC_SH" | cut -d: -f1)
[ -n "$gate_line" ] && [ -n "$swap_line" ] && [ "$gate_line" -lt "$swap_line" ] \
  && ok "the gate runs BEFORE the swap (line $gate_line < $swap_line)" \
  || bad "the gate does not run before the swap -- it would refuse a volume already destroyed"

# ── src and dist must behave identically ───────────────────────────────────
# dist is what is actually shipped to the box (cgc-db-index.yml scp's the dist copy),
# so a src-only fix reaches nobody.
if [ -f "$DIST_SH" ]; then
  src_fn="$(awk '/^zero_content_projects\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$SRC_SH")"
  dist_fn="$(awk '/^zero_content_projects\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$DIST_SH")"
  [ -n "$dist_fn" ] && [ "$src_fn" = "$dist_fn" ] \
    && ok "dist copy carries a byte-identical zero_content_projects()" \
    || bad "dist copy is missing or has drifted from src -- regenerate with 'sh build.sh workflow'"
else
  bad "dist copy not found at $DIST_SH"
fi

echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
