#!/usr/bin/env bash
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

# Stub gh: `repo view` returns $STUB_ISPRIVATE; `api <path> --jq .visibility`
# (GET) returns $STUB_CUR_VIS, or rc 1 when it is "absent" (package does not
# exist, which is what the pre-push gate keys on); `api --method DELETE <path>`
# is logged so a test can assert whether a delete was attempted, and succeeds
# unless $STUB_DELETE_RC=1.
#
# There is deliberately no PUT case. An earlier revision of this file asserted
# that each branch PUT a corrected visibility; GitHub has no set-visibility
# endpoint, that design was abandoned, and those assertions went stale and red
# while the script moved to delete-or-refuse. They are rewritten below against
# what the script actually does.
gh() {
  case "$1 $2" in
    "repo view")   printf '%s' "${STUB_ISPRIVATE:-}" ;;
    "api --method")
      echo "$3 $4" >> "$CALL_LOG"
      [ "${STUB_DELETE_RC:-0}" = "0" ]
      ;;
    *)
      [ "$1" = "api" ] || return 0
      [ "${STUB_CUR_VIS:-unknown}" = "absent" ] && return 1
      printf '%s' "${STUB_CUR_VIS:-unknown}"
      ;;
  esac
}

echo "── verify_or_delete_repo_pkg (POST-push backstop: delete, never expose) ──"
: > "$CALL_LOG"; STUB_ISPRIVATE=true  STUB_CUR_VIS=public
out=$(verify_or_delete_repo_pkg cgc-db-cloud-infra cloud-infra 2>&1); rc=$?
{ [ "$rc" -ne 0 ] && echo "$out" | grep -q "::error::" && echo "$out" | grep -q "DELETED" \
  && grep -q "DELETE /user/packages/container/cgc-db-cloud-infra" "$CALL_LOG"; } \
  && ok "backstop: private repo + public pkg -> DELETED, ::error::, non-zero" || bad "case A: rc=$rc out=[$out] log=[$(cat "$CALL_LOG")]"

: > "$CALL_LOG"; STUB_ISPRIVATE=true  STUB_CUR_VIS=private
out=$(verify_or_delete_repo_pkg cgc-db-cloud-infra cloud-infra 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && ! echo "$out" | grep -q "::error::" && [ ! -s "$CALL_LOG" ]; } \
  && ok "backstop: private repo + private pkg -> no-op, nothing deleted" || bad "case B: rc=$rc out=[$out] log=[$(cat "$CALL_LOG")]"

: > "$CALL_LOG"; STUB_ISPRIVATE=false STUB_CUR_VIS=public
out=$(verify_or_delete_repo_pkg cgc-db-front front 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && ! echo "$out" | grep -q "::error::" && [ ! -s "$CALL_LOG" ]; } \
  && ok "backstop: public repo -> check skipped entirely" || bad "case C: rc=$rc out=[$out] log=[$(cat "$CALL_LOG")]"

: > "$CALL_LOG"; STUB_ISPRIVATE=false STUB_CUR_VIS=public
out=$(verify_or_delete_repo_pkg cgc-db-unmapped unmapped 2>&1); rc=$?
{ [ "$rc" -ne 0 ] && echo "$out" | grep -q "not found in repo_map" && grep -q "^DELETE " "$CALL_LOG"; } \
  && ok "backstop: local_name absent from repo_map -> fail-safe private, deleted" || bad "case D: rc=$rc out=[$out] log=[$(cat "$CALL_LOG")]"

: > "$CALL_LOG"; STUB_ISPRIVATE="weird-garbage" STUB_CUR_VIS=public
out=$(verify_or_delete_repo_pkg cgc-db-cloud-infra cloud-infra 2>&1); rc=$?
{ [ "$rc" -ne 0 ] && echo "$out" | grep -q "could not determine visibility" && grep -q "^DELETE " "$CALL_LOG"; } \
  && ok "backstop: gh repo view undetermined -> fail-safe private, deleted" || bad "case E: rc=$rc out=[$out] log=[$(cat "$CALL_LOG")]"

: > "$CALL_LOG"; STUB_ISPRIVATE=true STUB_CUR_VIS=public STUB_DELETE_RC=1
out=$(verify_or_delete_repo_pkg cgc-db-cloud-infra cloud-infra 2>&1); rc=$?
{ [ "$rc" -ne 0 ] && echo "$out" | grep -q "could NOT delete"; } \
  && ok "backstop: delete failure surfaced as ::error::" || bad "case F: rc=$rc out=[$out]"
unset STUB_DELETE_RC

echo "── gate_repo_push (PRE-push gate: never create a public pkg from a private repo) ──"
: > "$CALL_LOG"; STUB_ISPRIVATE=false STUB_CUR_VIS=absent
out=$(gate_repo_push cgc-db-front front 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ] && [ ! -s "$CALL_LOG" ]; } \
  && ok "gate: public repo -> push allowed, package not even queried" || bad "case G: rc=$rc out=[$out]"

: > "$CALL_LOG"; STUB_ISPRIVATE=true STUB_CUR_VIS=private
out=$(gate_repo_push cgc-db-cloud-infra cloud-infra 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -q "pushing" && ! echo "$out" | grep -qE "::error::|::warning::"; } \
  && ok "gate: private repo + existing PRIVATE pkg -> push allowed" || bad "case H: rc=$rc out=[$out]"

# The case that matters: cloud-data / my-ai_memory with no package yet. Whether
# a push is safe here depends ENTIRELY on which token pushes.
: > "$CALL_LOG"; STUB_ISPRIVATE=true STUB_CUR_VIS=absent; unset CGC_GHCR_PAT
out=$(gate_repo_push cgc-db-cloud-data cloud-infra 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -q "::warning::" && echo "$out" | grep -q "NOT PUBLISHED" \
  && ! echo "$out" | grep -q "::error::" && [ ! -s "$CALL_LOG" ]; } \
  && ok "gate: private + no pkg + NO pat -> skipped (GITHUB_TOKEN would create it public)" || bad "case I: rc=$rc out=[$out]"

: > "$CALL_LOG"; STUB_ISPRIVATE=true STUB_CUR_VIS=absent; export CGC_GHCR_PAT=nonempty
out=$(gate_repo_push cgc-db-cloud-data cloud-infra 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -q "GHCR creates it PRIVATE" \
  && ! echo "$out" | grep -qE "::error::|::warning::"; } \
  && ok "gate: private + no pkg + PAT -> push allowed (born private via LABEL)" || bad "case I2: rc=$rc out=[$out]"

# Fail-safe "private" (repo could not be resolved) must NOT push even WITH a PAT:
# a token that cannot see the repo cannot auto-link it either, so the package
# would be created public.
: > "$CALL_LOG"; STUB_ISPRIVATE="weird-garbage" STUB_CUR_VIS=absent; export CGC_GHCR_PAT=nonempty
out=$(gate_repo_push cgc-db-cloud-data cloud-infra 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -q "::warning::" && echo "$out" | grep -q "NOT PUBLISHED"; } \
  && ok "gate: undetermined visibility + PAT -> still skipped (fail-safe is not proof)" || bad "case I3: rc=$rc out=[$out]"
unset CGC_GHCR_PAT

# And the gate must REFUSE, not delete — deleting is the backstop's job, and
# doing it here would race a package a human may have just fixed by hand.
: > "$CALL_LOG"; STUB_ISPRIVATE=true STUB_CUR_VIS=public
out=$(gate_repo_push cgc-db-cloud-data cloud-infra 2>&1); rc=$?
{ [ "$rc" -ne 0 ] && echo "$out" | grep -q "::error::" && echo "$out" | grep -q "refusing to push" \
  && [ ! -s "$CALL_LOG" ]; } \
  && ok "gate: private repo + PUBLIC pkg -> refused, nothing deleted here" || bad "case J: rc=$rc out=[$out] log=[$(cat "$CALL_LOG")]"

# monolith mode (refactor-equivalence smoke test — behaviour is unchanged,
# only moved into a function)
: > "$CALL_LOG"; STUB_ISPRIVATE=false STUB_CUR_VIS=public
out=$(visibility_monolith cloud-cgc-pub-mcp-octocode-db 2>&1)
{ ! echo "$out" | grep -q "::error::" && [ ! -s "$CALL_LOG" ]; } \
  && ok "monolith: no private repo_map entries -> no-op" || bad "case H: out=[$out] log=[$(cat "$CALL_LOG")]"

: > "$CALL_LOG"; STUB_ISPRIVATE=true STUB_CUR_VIS=public
out=$(visibility_monolith cloud-cgc-pub-mcp-octocode-db 2>&1)
{ echo "$out" | grep -q "::error::" && echo "$out" | grep -q "DELETE OR PRIVATE IT" && [ ! -s "$CALL_LOG" ]; } \
  && ok "monolith: private repo_map entries -> reported, never auto-touched" || bad "case K: out=[$out] log=[$(cat "$CALL_LOG")]"

# base mode — no associated repo; always public (model caches only, no
# project content to leak), so a PUT failure is a warning, never ::error::.
: > "$CALL_LOG"; STUB_CUR_VIS=public
out=$(visibility_base cgc-db-base 2>&1)
{ ! echo "$out" | grep -qE "::error::|::warning::" && [ ! -s "$CALL_LOG" ]; } \
  && ok "base: already public -> no-op" || bad "base public: out=[$out] log=[$(cat "$CALL_LOG")]"

: > "$CALL_LOG"; STUB_CUR_VIS=private
out=$(visibility_base cgc-db-base 2>&1)
{ echo "$out" | grep -q "::warning::" && ! echo "$out" | grep -q "::error::" && [ ! -s "$CALL_LOG" ]; } \
  && ok "base: private -> ::warning:: only (nothing to leak, no endpoint to fix it)" || bad "base private: out=[$out] log=[$(cat "$CALL_LOG")]"

echo ""
echo "═══════════════════════════════════════"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ] || exit 1
