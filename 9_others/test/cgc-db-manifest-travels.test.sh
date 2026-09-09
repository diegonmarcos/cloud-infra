#!/usr/bin/env bash
# Tester for the ONE property that made the cgc index rot silently (2026-09-09):
#
#   the per-phase manifest cloud-cgc-db-update.sh writes must be INSIDE the tar
#   cloud-cgc-db-package.sh builds for that repo.
#
# It was not. update.sh wrote $OCTO_HOME/.cgc-manifest-<phase>.json at the home
# ROOT; package.sh's build_repo_tar tars only the project dir and build_base_tar
# only config.toml + fastembed/ + sentencetransformer/. Neither allowlist
# contains a root file, so every run wrote the manifest, packaged an image
# without it, and the next run read {} again -- "was=none" for every repo in
# runs 34267362724 and 34392223176, including repos indexed hours earlier.
#
# Nothing failed. The pipeline simply had no record of which commit the served
# index corresponded to, so a repo that never converged looked exactly like one
# that was current, and cloud-u-android served a deleted FairEmail tree for a
# day behind green runs.
#
# WHY THIS TEST IS A ROUND TRIP AND NOT A MIRROR: cgc-db-gate.test.sh already
# covered the manifest read/write expressions by re-implementing them, and
# passed throughout -- the expressions were always right, the PATH was wrong. So
# this drives the REAL producer function (manifest_path, extracted from
# update.sh by name) into the REAL consumer function (build_repo_tar, sourced
# from package.sh) and asserts the file comes out the other side.
set -uo pipefail

# Repo root by upward search, not a fixed ../../.. -- this file exists at BOTH
# 9_others/test/ and 9_others/dist/test/ (generated), at different depths.
REPO_ROOT="$(_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
UPD_SH="$REPO_ROOT/1_cicd/src/ops/cloud-cgc-db-update.sh"
PKG_SH="$REPO_ROOT/1_cicd/src/ops/cloud-cgc-db-package.sh"
[ -f "$UPD_SH" ] || { echo "::error::cloud-cgc-db-update.sh not found at $UPD_SH"; exit 1; }
[ -f "$PKG_SH" ] || { echo "::error::cloud-cgc-db-package.sh not found at $PKG_SH"; exit 1; }

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }

# The packaging side offers a source-only mode; use it so build_repo_tar and
# build_base_tar under test are byte-identical to the ones CI runs.
# shellcheck disable=SC1090
CGC_PKG_SOURCE_ONLY=1 source "$PKG_SH"
set +e +u
set +o pipefail 2>/dev/null || true

# The producer side is a straight-line script with no source-only mode, so lift
# the three functions out BY NAME. Extraction is deliberate: rename or move one
# of them and this test fails to define it and dies, rather than quietly
# testing a copy that no longer matches production.
for fn in project_dirs_snapshot manifest_path manifest_read; do
  body=$(sed -n "/^${fn}() {/,/^}/p" "$UPD_SH")
  [ -n "$body" ] || { echo "::error::$fn() not found in $UPD_SH -- was it renamed? This test must be updated with it."; exit 1; }
  eval "$body"
done

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

# A per-repo octocode home exactly as a matrix job sees it after restore:
# base root state (config.toml + model caches) plus this repo's ONE project dir.
OCTO_HOME="$W/home"
PROJ=64ced47c82d6526d
mkdir -p "$OCTO_HOME/$PROJ/storage" "$OCTO_HOME/fastembed" "$OCTO_HOME/sentencetransformer"
: > "$OCTO_HOME/config.toml"
: > "$OCTO_HOME/$PROJ/storage/code_blocks.lance"
MANIFEST_NAME=".cgc-manifest-semantic.json"
MANIFEST="$OCTO_HOME/$MANIFEST_NAME"
echo '{}' > "$MANIFEST"

echo "── manifest_path: where the indexed commit gets written ──"
CGC_PACKAGE_MODE=per-repo
[ "$(manifest_path '')" = "$OCTO_HOME/$PROJ/$MANIFEST_NAME" ] \
  && ok "per-repo mode, one restored project dir -> manifest inside it" \
  || bad "per-repo mode must place the manifest inside the project dir (got '$(manifest_path '')')"
[ "$(manifest_path "$PROJ")" = "$OCTO_HOME/$PROJ/$MANIFEST_NAME" ] \
  && ok "caller-supplied project dir (post-index write path) is honoured" \
  || bad "explicit project dir must be honoured"
CGC_PACKAGE_MODE=monolith
[ "$(manifest_path '')" = "$MANIFEST" ] \
  && ok "monolith mode keeps the home-root manifest (that packaging tars the whole home)" \
  || bad "monolith mode must be unchanged"
CGC_PACKAGE_MODE=per-repo
[ "$(manifest_path nonexistent-dir)" = "$MANIFEST" ] \
  && ok "unknown project dir falls back to root, i.e. reads as 'never indexed'" \
  || bad "unknown project dir must fall back to root"

# First cycle for a repo: no image on GHCR yet, so no project dir was restored.
EMPTY_HOME="$W/empty"; mkdir -p "$EMPTY_HOME/fastembed"; : > "$EMPTY_HOME/config.toml"
( OCTO_HOME="$EMPTY_HOME"; MANIFEST="$EMPTY_HOME/$MANIFEST_NAME"
  [ "$(manifest_path '')" = "$EMPTY_HOME/$MANIFEST_NAME" ] ) \
  && ok "no project dir yet -> root fallback (a first index must not claim a commit)" \
  || bad "empty home must fall back to root"

echo "── manifest_read ──"
[ -z "$(manifest_read "$W/does-not-exist.json" cloud-u-android)" ] \
  && ok "absent manifest reads empty, not an error (set -e safe)" \
  || bad "absent manifest must read empty"
echo '{"cloud-u-android":"7ee6c232"}' > "$OCTO_HOME/$PROJ/$MANIFEST_NAME"
[ "$(manifest_read "$OCTO_HOME/$PROJ/$MANIFEST_NAME" cloud-u-android)" = "7ee6c232" ] \
  && ok "recorded commit is read back" || bad "recorded commit must be read back"
[ -z "$(manifest_read "$OCTO_HOME/$PROJ/$MANIFEST_NAME" front)" ] \
  && ok "repo absent from the manifest reads empty (must index, never skip)" \
  || bad "absent repo must read empty"

echo "── ROUND TRIP: does the written manifest survive packaging? ──"
# This is the assertion the old placement failed.
CGC_PACKAGE_MODE=per-repo
# Clear the fixture manifest_read left in the project dir first: if it stayed,
# the tar would contain it no matter where manifest_path decided to write, and
# this assertion would pass even with the root-placement bug reintroduced.
rm -f "$OCTO_HOME/$PROJ/$MANIFEST_NAME"
WROTE=$(manifest_path "$PROJ")
echo '{"cloud-u-android":"7ee6c232"}' > "$WROTE"
build_repo_tar "$OCTO_HOME" "$W/repo.tar" "$PROJ" 2>/dev/null
tar tf "$W/repo.tar" | grep -qx "$PROJ/$MANIFEST_NAME" \
  && ok "manifest is inside cgc-db-<repo>:latest, so it travels with the DB it describes" \
  || bad "manifest MISSING from the per-repo tar -- the change gate would read {} again"

# The root copy is what used to be written, and it is still not packaged by
# either tar. Pin that so nobody 'fixes' this by putting it back at the root.
tar tf "$W/repo.tar" | grep -qx "$MANIFEST_NAME" \
  && bad "root manifest unexpectedly in the repo tar" \
  || ok "a home-ROOT manifest is still absent from the repo tar (the original bug, pinned)"
build_base_tar "$OCTO_HOME" "$W/base.tar" 2>/dev/null
tar tf "$W/base.tar" | grep -qx "$MANIFEST_NAME" \
  && bad "root manifest unexpectedly in the base tar" \
  || ok "a home-ROOT manifest is still absent from the base tar (the original bug, pinned)"

echo "── no cross-repo clobbering when restore-all layers the images ──"
# restore-all cp -a's every per-repo image into ONE home. Each repo's manifest
# rides inside its own project dir, so two repos cannot overwrite each other's
# record -- which a single shared root file would have done, last write winning.
OTHER=aa11bb22cc33dd44
mkdir -p "$OCTO_HOME/$OTHER"
echo '{"cloud-infra":"453c27a3"}' > "$OCTO_HOME/$OTHER/$MANIFEST_NAME"
[ "$(manifest_read "$OCTO_HOME/$PROJ/$MANIFEST_NAME" cloud-u-android)" = "7ee6c232" ] \
  && [ "$(manifest_read "$OCTO_HOME/$OTHER/$MANIFEST_NAME" cloud-infra)" = "453c27a3" ] \
  && ok "two repos keep their own indexed commits in one assembled home" \
  || bad "per-repo records must not collide"
# With two project dirs present the discover path is ambiguous, so it must
# refuse to guess rather than hand one repo the other's commit.
[ "$(manifest_path '')" = "$MANIFEST" ] \
  && ok "ambiguous home (2+ project dirs) falls back to root instead of guessing" \
  || bad "ambiguous home must not pick a project dir"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
