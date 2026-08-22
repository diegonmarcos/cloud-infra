#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/cgc-db-package.test.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Tester for cloud-cgc-db-package.sh's per-repo/base packaging (2026-08-21):
#   - MODE auto-detection from the image name (monolith / base / repo:<name>)
#   - single-project-dir detection (0 dirs = error, 2+ dirs = error naming them)
#   - the tar exclude logic (repo: drop index.lock/logs//latest_log.txt;
#     base: allowlist config.toml+fastembed/+sentencetransformer/ only)
#   - the visibility decision table (repo / base / monolith)
#
# Sources the REAL ops script (CGC_PKG_SOURCE_ONLY=1 defines every function
# and calls none) so the tested logic stays 1:1 with production; gh is
# stubbed to drive deterministic visibility scenarios without network/auth.
set -uo pipefail

# Repo root by upward search, not a fixed ../../.. — this file exists at BOTH
# 9_others/test/ and 9_others/dist/test/ (generated), which sit at
# different depths, so one literal count is wrong for one of the two copies.
REPO_ROOT="$(_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
PKG_SH="$REPO_ROOT/1_cicd/src/ops/cloud-cgc-db-package.sh"
[ -f "$PKG_SH" ] || { echo "::error::cloud-cgc-db-package.sh not found at $PKG_SH"; exit 1; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }

# shellcheck disable=SC1090
CGC_PKG_SOURCE_ONLY=1 source "$PKG_SH"
# package.sh sets -eu at its own top level; sourcing carries that into THIS
# shell. Relax it back so the harness can inspect non-zero returns itself —
# the functions under test are already defined regardless.
set +e +u
set +o pipefail 2>/dev/null || true

echo "── detect_mode (image name → packaging mode) ──"
[ "$(detect_mode cloud-cgc-pub-mcp-octocode-db)" = "monolith" ] \
  && ok "unrelated image name -> monolith (unchanged path)" || bad "monolith detection"
[ "$(detect_mode cgc-db-base)" = "base" ] \
  && ok "cgc-db-base -> base" || bad "base detection"
[ "$(detect_mode cgc-db-cloud-infra)" = "repo:cloud-infra" ] \
  && ok "cgc-db-cloud-infra -> repo:cloud-infra" || bad "repo detection"
[ "$(detect_mode cgc-db-cloud-mykonsole-dtk)" = "repo:cloud-mykonsole-dtk" ] \
  && ok "dash-heavy local_name preserved (only the cgc-db- prefix is stripped)" || bad "repo detection (dashed name)"

echo "── find_project_dir (single-project-dir detection) ──"
mkdir -p "$W/src1/fastembed" "$W/src1/sentencetransformer"
echo cfg > "$W/src1/config.toml"
out=$(find_project_dir "$W/src1" 2>"$W/err1"); rc=$?
if [ "$rc" -ne 0 ] && grep -q "no project directory" "$W/err1"; then
  ok "0 project dirs -> error"
else
  bad "0 project dirs (rc=$rc out=$out err=$(cat "$W/err1"))"
fi

mkdir -p "$W/src2/fastembed" "$W/src2/sentencetransformer" "$W/src2/deadbeef0123abcd"
echo cfg > "$W/src2/config.toml"
out=$(find_project_dir "$W/src2" 2>"$W/err2"); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "deadbeef0123abcd" ]; then
  ok "exactly 1 project dir -> detected (model-cache dirs excluded)"
else
  bad "1 project dir (rc=$rc out=$out)"
fi

mkdir -p "$W/src3/fastembed" "$W/src3/aaa111" "$W/src3/bbb222"
out=$(find_project_dir "$W/src3" 2>"$W/err3"); rc=$?
if [ "$rc" -ne 0 ] && grep -q "aaa111" "$W/err3" && grep -q "bbb222" "$W/err3"; then
  ok "2 project dirs -> error naming both"
else
  bad "2 project dirs (rc=$rc err=$(cat "$W/err3"))"
fi

echo "── build_repo_tar (exclude logic) ──"
mkdir -p "$W/src4/proj999/logs"
echo lance  > "$W/src4/proj999/data.lance"
echo lock   > "$W/src4/proj999/index.lock"
echo log1   > "$W/src4/proj999/logs/run.log"
echo latest > "$W/src4/proj999/latest_log.txt"
build_repo_tar "$W/src4" "$W/repo.tar" proj999
contents=$(tar tf "$W/repo.tar")
echo "$contents" | grep -q "proj999/data.lance" && ok "project data kept" || bad "project data missing: $contents"
echo "$contents" | grep -q "index.lock"        && bad "index.lock NOT excluded (live-PID lockfile would deadlock the consumer): $contents" || ok "index.lock excluded"
echo "$contents" | grep -q "logs/"             && bad "logs/ NOT excluded: $contents" || ok "logs/ excluded"
echo "$contents" | grep -q "latest_log.txt"    && bad "latest_log.txt NOT excluded: $contents" || ok "latest_log.txt excluded"

echo "── build_base_tar (root-state allowlist) ──"
mkdir -p "$W/src5/fastembed" "$W/src5/sentencetransformer" "$W/src5/someproj123"
echo cfg > "$W/src5/config.toml"
echo m1  > "$W/src5/fastembed/m.bin"
echo m2  > "$W/src5/sentencetransformer/m.bin"
echo dat > "$W/src5/someproj123/data.lance"
build_base_tar "$W/src5" "$W/base.tar"
bcontents=$(tar tf "$W/base.tar")
echo "$bcontents" | grep -q "^config.toml$"          && ok "config.toml included" || bad "config.toml missing: $bcontents"
echo "$bcontents" | grep -q "^fastembed/"            && ok "fastembed/ included" || bad "fastembed/ missing"
echo "$bcontents" | grep -q "^sentencetransformer/"  && ok "sentencetransformer/ included" || bad "sentencetransformer/ missing"
echo "$bcontents" | grep -q "someproj123"            && bad "project dir LEAKED into base tar: $bcontents" || ok "project dir excluded from base (allowlist, not denylist)"

mkdir -p "$W/src6/onlyproj"
build_base_tar "$W/src6" "$W/base2.tar" 2>"$W/err6"; rc=$?
if [ "$rc" -ne 0 ] && grep -q "no root-state entries" "$W/err6"; then
  ok "base tar errors when no root-state entries exist"
else
  bad "base tar should have failed on an empty root (rc=$rc)"
fi

echo "── visibility decision table ──"
CALL_LOG="$W/gh_calls.log"
cat > "$W/bj.json" <<'JSON'
{"runtime":{"octocode":{"repo_map":{"cloud-infra":"cloud-infra","front":"diegonmarcos.github.io"}}}}
JSON
export CGC_BUILD_JSON="$W/bj.json"

# Stub gh: `repo view` returns $STUB_ISPRIVATE; `api .../visibility` (GET)
# returns $STUB_CUR_VIS; `api --method PUT .../visibility -f visibility=X`
# is logged (so the test can assert WHICH visibility was requested) and
# succeeds unless $STUB_PUT_RC=1.
gh() {
  case "$1 $2" in
    "repo view")   printf '%s' "${STUB_ISPRIVATE:-}" ;;
    "api --method")
      echo "PUT $4 $6" >> "$CALL_LOG"
      [ "${STUB_PUT_RC:-0}" = "0" ]
      ;;
    *) [ "$1" = "api" ] && printf '%s' "${STUB_CUR_VIS:-unknown}" ;;
  esac
}

# repo mode
: > "$CALL_LOG"; STUB_ISPRIVATE=true  STUB_CUR_VIS=public
out=$(visibility_repo cgc-db-cloud-infra cloud-infra 2>&1)
{ echo "$out" | grep -q "::error::" && grep -q "visibility=private" "$CALL_LOG"; } \
  && ok "repo: private+public -> forced private with ::error::" || bad "case A: out=[$out] log=[$(cat "$CALL_LOG")]"

: > "$CALL_LOG"; STUB_ISPRIVATE=true  STUB_CUR_VIS=private
out=$(visibility_repo cgc-db-cloud-infra cloud-infra 2>&1)
{ ! echo "$out" | grep -q "::error::" && [ ! -s "$CALL_LOG" ]; } \
  && ok "repo: private+private -> no-op, no error" || bad "case B: out=[$out] log=[$(cat "$CALL_LOG")]"

: > "$CALL_LOG"; STUB_ISPRIVATE=false STUB_CUR_VIS=private
out=$(visibility_repo cgc-db-front front 2>&1)
{ ! echo "$out" | grep -q "::error::" && grep -q "visibility=public" "$CALL_LOG"; } \
  && ok "repo: public+private -> corrected to public, no error" || bad "case C: out=[$out] log=[$(cat "$CALL_LOG")]"

: > "$CALL_LOG"; STUB_ISPRIVATE=false STUB_CUR_VIS=public
out=$(visibility_repo cgc-db-front front 2>&1)
{ ! echo "$out" | grep -q "::error::" && [ ! -s "$CALL_LOG" ]; } \
  && ok "repo: public+public -> no-op" || bad "case D: out=[$out] log=[$(cat "$CALL_LOG")]"

: > "$CALL_LOG"; STUB_ISPRIVATE=false STUB_CUR_VIS=public
out=$(visibility_repo cgc-db-unmapped unmapped 2>&1)
{ echo "$out" | grep -q "::error::" && echo "$out" | grep -q "not found in repo_map" && grep -q "visibility=private" "$CALL_LOG"; } \
  && ok "repo: local_name absent from repo_map -> fail-safe private" || bad "case E: out=[$out] log=[$(cat "$CALL_LOG")]"

: > "$CALL_LOG"; STUB_ISPRIVATE="weird-garbage" STUB_CUR_VIS=public
out=$(visibility_repo cgc-db-cloud-infra cloud-infra 2>&1)
{ echo "$out" | grep -q "::error::" && echo "$out" | grep -q "could not determine visibility" && grep -q "visibility=private" "$CALL_LOG"; } \
  && ok "repo: gh repo view undetermined -> fail-safe private" || bad "case F: out=[$out] log=[$(cat "$CALL_LOG")]"

: > "$CALL_LOG"; STUB_ISPRIVATE=true STUB_CUR_VIS=public STUB_PUT_RC=1
out=$(visibility_repo cgc-db-cloud-infra cloud-infra 2>&1)
echo "$out" | grep -q "could NOT set" && ok "repo: PUT failure surfaced" || bad "case G: out=[$out]"
unset STUB_PUT_RC

# monolith mode (refactor-equivalence smoke test — behaviour is unchanged,
# only moved into a function)
: > "$CALL_LOG"; STUB_ISPRIVATE=false STUB_CUR_VIS=public
out=$(visibility_monolith cloud-cgc-pub-mcp-octocode-db 2>&1)
{ ! echo "$out" | grep -q "::error::" && [ ! -s "$CALL_LOG" ]; } \
  && ok "monolith: no private repo_map entries -> no-op" || bad "case H: out=[$out] log=[$(cat "$CALL_LOG")]"

: > "$CALL_LOG"; STUB_ISPRIVATE=true STUB_CUR_VIS=public
out=$(visibility_monolith cloud-cgc-pub-mcp-octocode-db 2>&1)
{ echo "$out" | grep -q "::error::" && grep -q "visibility=private" "$CALL_LOG"; } \
  && ok "monolith: private repo_map entries -> forced private" || bad "case I: out=[$out] log=[$(cat "$CALL_LOG")]"

# base mode — no associated repo; always public (model caches only, no
# project content to leak), so a PUT failure is a warning, never ::error::.
: > "$CALL_LOG"; STUB_CUR_VIS=public
out=$(visibility_base cgc-db-base 2>&1)
{ ! echo "$out" | grep -qE "::error::|::warning::" && [ ! -s "$CALL_LOG" ]; } \
  && ok "base: already public -> no-op" || bad "base public: out=[$out] log=[$(cat "$CALL_LOG")]"

: > "$CALL_LOG"; STUB_CUR_VIS=private
out=$(visibility_base cgc-db-base 2>&1)
{ grep -q "visibility=public" "$CALL_LOG" && ! echo "$out" | grep -q "::error::"; } \
  && ok "base: private -> corrected to public, no ::error::" || bad "base private->public: out=[$out] log=[$(cat "$CALL_LOG")]"

: > "$CALL_LOG"; STUB_CUR_VIS=private STUB_PUT_RC=1
out=$(visibility_base cgc-db-base 2>&1)
{ echo "$out" | grep -q "::warning::" && ! echo "$out" | grep -q "::error::"; } \
  && ok "base: PUT failure -> ::warning:: (never ::error:: — nothing to leak)" || bad "base PUT-failure severity: out=[$out]"
unset STUB_PUT_RC

echo ""
echo "═══════════════════════════════════════"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ] || exit 1
