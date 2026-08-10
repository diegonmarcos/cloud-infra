#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 8 tester — every declared GHCR image is public             ║
# ║                                                                  ║
# ║ Proves:                                                          ║
# ║   Every `docker.image` declared in a_solutions/*/build.json is   ║
# ║   public on ghcr.io/diegonmarcos — prevents the recurring        ║
# ║   "write_package denied" deploy class (umami, caddy, hickory-dns ║
# ║   were all private at some point in 2026-04).                    ║
# ║                                                                  ║
# ║ Data-driven: iterates every build.json; no hardcoded image list. ║
# ║ Skipped when `gh` is unauthenticated (local dev without token).  ║
# ║                                                                  ║
# ║ Usage: bash 1_configs/src/test/test_ghcr_visibility.sh         ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

# Repo root by upward search, not a fixed ../../.. — this file exists at BOTH
# 1_configs/src/test/ and 1_configs/dist/test/ (generated), which sit at
# different depths, so one literal count is wrong for one of the two copies.
REPO_ROOT="$(_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── Every declared docker.image must be public on GHCR ──"

if ! command -v gh >/dev/null 2>&1; then
    echo "  ⚠ gh CLI not installed — skipping (not a failure)"
    exit 0
fi
if ! gh auth status >/dev/null 2>&1; then
    echo "  ⚠ gh not authenticated — skipping (not a failure)"
    exit 0
fi

_ghcr_visibility() {
    # Returns "public", "private", "absent" (404), or empty on other error.
    local pkg="$1"
    local body http
    body=$(gh api "/user/packages/container/$pkg" 2>/dev/null) || {
        http=$(gh api -i "/user/packages/container/$pkg" 2>/dev/null | head -1 || echo "")
        case "$http" in
            *404*) echo "absent"; return 0 ;;
        esac
        return 1
    }
    echo "$body" | jq -r '.visibility // empty'
}

images=$(find "$REPO_ROOT/a_solutions" -maxdepth 2 -name build.json \
    -not -path "*/z_archive/*" -print0 2>/dev/null \
    | xargs -0 -I{} jq -r '
        select(.docker.registry == "ghcr.io/diegonmarcos")
        | .docker.image // empty' {} 2>/dev/null \
    | sort -u | grep -v '^$' || true)

if [ -z "$images" ]; then
    echo "  (no declared GHCR images found)"
    exit 0
fi

checked=0
private_count=0
for img in $images; do
    checked=$((checked + 1))
    vis=$(_ghcr_visibility "$img" || echo "")
    case "$vis" in
        public)  pass "$img: public" ;;
        private)
            fail "$img: PRIVATE — write_package will deny. Fix via GitHub UI or: gh api -X PATCH /user/packages/container/$img -f visibility=public"
            private_count=$((private_count + 1))
            ;;
        absent)  echo "  • $img: not yet published (first ship will create)" ;;
        "")      echo "  • $img: visibility check failed (skipped)" ;;
        *)       fail "$img: unexpected visibility '$vis'" ;;
    esac
done

echo ""
echo "── Sibling images from compose dockerfile_inline ──"
# mkGhcrBuild wraps a base image under a different name (e.g. umami → umami + umami-db).
# Extract ghcr.io/diegonmarcos/* refs from every dist/docker-compose.yml for coverage.
for cy in "$REPO_ROOT"/a_solutions/*/dist/docker-compose.yml; do
    [ -f "$cy" ] || continue
    svc_dir=$(basename "$(dirname "$(dirname "$cy")")")
    while read -r img_name; do
        [ -n "$img_name" ] || continue
        if echo "$images" | grep -qx "$img_name"; then continue; fi
        vis=$(_ghcr_visibility "$img_name" || echo "")
        case "$vis" in
            public) pass "$img_name (via $svc_dir): public" ;;
            private)
                fail "$img_name (via $svc_dir): PRIVATE — flip via GitHub UI"
                private_count=$((private_count + 1))
                ;;
            absent|"") ;;
            *) fail "$img_name: unexpected visibility '$vis'" ;;
        esac
    done < <(grep -oE 'ghcr\.io/diegonmarcos/[a-z0-9_-]+' "$cy" \
        | awk -F/ '{print $NF}' | awk -F: '{print $1}' | sort -u)
done

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "══════════════════════════════════════════════"
    echo "Phase 8 GHCR visibility: PASS ($checked primary images)"
    echo "══════════════════════════════════════════════"
    exit 0
else
    echo "══════════════════════════════════════════════"
    echo "Phase 8 GHCR visibility: FAIL ($private_count private)"
    echo "══════════════════════════════════════════════"
    exit 1
fi
