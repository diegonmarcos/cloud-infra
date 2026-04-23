#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_workflows/src/test/test_service_header_present.sh
# ║   Engine : 1_workflows/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
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
# ║ Usage: bash 1_workflows/src/test/test_service_header_present.sh  ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HEADER_JSON="$REPO_ROOT/1_workflows/src/libs/generated-header.json"
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

echo "── a_solutions/*/dist/ (container engine) ──"
for bj in "$REPO_ROOT"/a_solutions/*/build.json; do
    [ -f "$bj" ] || continue
    check_service "$(dirname "$bj")"
done

if [ -d "$REPO_ROOT/b_infra/home-manager" ]; then
    echo ""
    echo "── b_infra/home-manager/*/dist/ (HM engine) ──"
    for d in "$REPO_ROOT"/b_infra/home-manager/*/; do
        check_service "${d%/}"
    done
fi

if [ -d "$REPO_ROOT/c_vps" ]; then
    echo ""
    echo "── c_vps/*/dist/ (terraform engine) ──"
    for d in "$REPO_ROOT"/c_vps/*/; do
        check_service "${d%/}"
    done
fi

echo ""
if [ "$CHECKED" -eq 0 ]; then
    echo "══════════════════════════════════════════════"
    echo "service header presence: SKIPPED (0 in-scope files)"
    echo "Run ./build.sh build on a service to populate dist/."
    echo "══════════════════════════════════════════════"
    exit 0
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
