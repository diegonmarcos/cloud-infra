#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_service_header_present.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 2 tester — service dist/ files copied from src/ are stamped║
# ║                                                                  ║
# ║ Scope:                                                           ║
# ║   Opt-in per service via build.json `build.headers_enforced:     ║
# ║   true`. When set, every file that exists at src/<path> AND      ║
# ║   dist/<path> (identical relative path) must carry the GENERATED ║
# ║   banner. Everything else in dist/ (nix-build outputs, wrangler  ║
# ║   caches, .secrets, .result) is out of scope.                    ║
# ║                                                                  ║
# ║   Services without the flag are skipped — Phase 2 rolls out      ║
# ║   gradually, one service at a time, as they opt in.              ║
# ║                                                                  ║
# ║ Usage: bash 9_others/test/test_service_header_present.sh  ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

# Repo root by upward search, not a fixed ../../.. — this file exists at BOTH
# 9_others/test/ and 1_cicd/dist/test/ (generated), which sit at
# different depths, so one literal count is wrong for one of the two copies.
REPO_ROOT="$(_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
HEADER_JSON="$REPO_ROOT/9_others/src/generated-header.json"
MARKER="$(jq -r '.marker' "$HEADER_JSON")"

FAIL=0
CHECKED=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

expects_stamp() {
    local path="$1" base ext
    base="$(basename "$path")"
    ext="${base##*.}"
    if jq -er --arg b "$base" '(.skip_basenames // [])[] | select(. == $b)' "$HEADER_JSON" >/dev/null 2>&1; then
        return 1
    fi
    if jq -er --arg b "$base" '.skip_extensions[] | select(. as $e | $b | endswith("." + $e))' "$HEADER_JSON" >/dev/null 2>&1; then
        return 1
    fi
    if [ "$ext" = "json" ]; then
        [ "${INJECT_JSON:-0}" = "1" ] && return 0 || return 1
    fi
    [ -n "$(jq -r --arg n "$base" '.comment_by_basename[$n] // empty' "$HEADER_JSON")" ] && return 0
    if [ "$ext" != "$base" ] && [ -n "$(jq -r --arg e "$ext" '.comment_by_ext[$e] // empty' "$HEADER_JSON")" ]; then
        return 0
    fi
    return 1
}

check_service() {
    local service_dir="$1"
    local src_dir="$service_dir/src"
    local dist_dir="$service_dir/dist"
    local build_json="$service_dir/build.json"
    [ -d "$src_dir" ]  || return 0
    [ -d "$dist_dir" ] || return 0
    # Opt-in gate: service must declare build.headers_enforced == true.
    if [ -f "$build_json" ]; then
        local enforced
        enforced=$(jq -r '.build.headers_enforced // false' "$build_json" 2>/dev/null)
        [ "$enforced" = "true" ] || return 0
    else
        return 0
    fi

    local src_file rel dist_file svc_label
    svc_label="$(basename "$service_dir")"
    # Iterate every file under src/ (dereferencing symlinks, matching `cp -L`).
    while IFS= read -r -d '' src_file; do
        rel="${src_file#$src_dir/}"
        dist_file="$dist_dir/$rel"
        [ -f "$dist_file" ] || continue
        if expects_stamp "$dist_file"; then
            CHECKED=$((CHECKED + 1))
            if head -n 20 "$dist_file" | grep -qF "$MARKER"; then
                pass "${dist_file#$REPO_ROOT/}"
            else
                fail "${dist_file#$REPO_ROOT/} — missing '$MARKER' (service: $svc_label)"
            fi
        fi
    done < <(find -L "$src_dir" -type f -print0 2>/dev/null)
}

# ── Scope roots, read as data from generated-header.json ──
#
# These were three copy-pasted blocks, and a_solutions/ was reached by a glob
# that simply iterates zero times when the directory is not there. a_solutions
# is a SEPARATE repository (diegonmarcos/cloud-u-containers) that CI checks out
# into this path, so "not there" is the normal state of any checkout that
# forgot the checkout step — and in that state this tester scanned b_infra and
# c_vps, found them clean, and printed "PASS (304 files checked)". The container
# engine, which is the scope this tester was written for, was silently absent
# from a result that looked like thorough coverage.
#
# A check that cannot reach its subject must FAIL, never go quiet. Both
# reachability conditions below are therefore failures, not skips:
#   - a scope glob that matches NO service directory at all
#   - a scope that matches directories but contributes ZERO in-scope files
SCOPES_TSV="$(jq -r '(.enforced_scopes.scopes // [])[] | "\(.glob)\t\(.label)"' "$HEADER_JSON")"
[ -n "$SCOPES_TSV" ] || { echo "::error::generated-header.json declares no enforced_scopes — this tester has no subject to check" >&2; exit 1; }

while IFS="$(printf '\t')" read -r scope_glob scope_label; do
    [ -n "$scope_glob" ] || continue
    echo ""
    echo "── $scope_label ──"
    scope_dirs=0
    scope_before="$CHECKED"
    for d in "$REPO_ROOT"/$scope_glob; do
        [ -d "$d" ] || continue
        scope_dirs=$((scope_dirs + 1))
        check_service "${d%/}"
    done
    if [ "$scope_dirs" -eq 0 ]; then
        fail "scope '$scope_label' — glob '$scope_glob' matched NO service directory. The subject of this check is not present, so nothing about it was verified. If this is a_solutions/, the cloud-u-containers checkout is missing."
        continue
    fi
    scope_checked=$((CHECKED - scope_before))
    if [ "$scope_checked" -eq 0 ]; then
        fail "scope '$scope_label' — $scope_dirs service directory/ies present but ZERO in-scope files checked. Either no service here sets build.headers_enforced, or no dist/ has been built; either way this scope certified nothing."
    else
        printf "  · %s: %s service dirs, %s files checked\n" "$scope_label" "$scope_dirs" "$scope_checked"
    fi
done <<SCOPES
$SCOPES_TSV
SCOPES

echo ""
# CHECKED == 0 was an `exit 0` with a "SKIPPED (0 in-scope files)" banner. That
# is the #363 shape exactly — a detector that reaches nothing and reports green.
# It is a failure now. The per-scope assertions above will normally fire first
# and say something more specific; this is the backstop.
if [ "$CHECKED" -eq 0 ]; then
    echo "══════════════════════════════════════════════"
    echo "service header presence: FAIL — 0 in-scope files across every declared scope."
    echo "This tester verified NOTHING. Build a service's dist/ (./build.sh build) or"
    echo "check that the declared scopes in generated-header.json still exist."
    echo "══════════════════════════════════════════════"
    exit 1
fi

if [ "$FAIL" -eq 0 ]; then
    echo "══════════════════════════════════════════════"
    echo "service header presence: PASS ($CHECKED files checked)"
    echo "══════════════════════════════════════════════"
    exit 0
else
    echo "══════════════════════════════════════════════"
    echo "service header presence: FAIL ($CHECKED files checked)"
    echo "══════════════════════════════════════════════"
    exit 1
fi
