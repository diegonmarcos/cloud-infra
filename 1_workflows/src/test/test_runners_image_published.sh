#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 17 tester — every runners[].builder_image is published     ║
# ║                                                                  ║
# ║ Regression guard for cloud-data-runners.json drifting away from  ║
# ║ the actually-published cloud-builder-x* image. If they diverge,  ║
# ║ ssh-runner builds fail on oci-apps with "denied: denied" trying  ║
# ║ to pull the non-existent runner image — and the engine's docker  ║
# ║ push step then logs "Pushed" UNCONDITIONALLY despite no image    ║
# ║ being built, masking the real cause.                             ║
# ║                                                                  ║
# ║ Data-driven (FIRE RULE 3): walks every runner declared in        ║
# ║ cloud-data-runners.json with type=ssh + builder_image set.       ║
# ║                                                                  ║
# ║ Skipped when gh is unauthenticated (local dev without token).    ║
# ║                                                                  ║
# ║ Usage:                                                           ║
# ║   bash 1_workflows/src/test/test_runners_image_published.sh      ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── Every runners[].builder_image must be published on GHCR ──"

if ! command -v gh >/dev/null 2>&1; then
    echo "  ⚠ gh CLI not installed — skipping (not a failure)"
    exit 0
fi
if ! gh auth status >/dev/null 2>&1; then
    echo "  ⚠ gh not authenticated — skipping (not a failure)"
    exit 0
fi

# Resolve runners.json — prefer derived dist/, fall back to cloud-data submodule
RUNNERS_JSON=""
for p in \
    "$REPO_ROOT/2_configs/dist/cloud-data-runners.json" \
    "$REPO_ROOT/I_cloud-data/cloud-data-runners.json" \
    "$REPO_ROOT/cloud-data/cloud-data-runners.json"; do
    [ -f "$p" ] && { RUNNERS_JSON="$p"; break; }
done
if [ -z "$RUNNERS_JSON" ]; then
    fail "cloud-data-runners.json not found"
    exit 1
fi
echo "  source: $RUNNERS_JSON"

CHECKED=0
while IFS=$'\t' read -r arch image; do
    [ -z "$image" ] && continue
    # Strip ghcr.io/<user>/  prefix and  :tag  suffix → bare package name
    pkg=$(echo "$image" | awk -F/ '{print $NF}' | awk -F: '{print $1}')

    body=$(gh api "/user/packages/container/$pkg" 2>/dev/null) || {
        http=$(gh api -i "/user/packages/container/$pkg" 2>/dev/null | head -1 || echo "")
        case "$http" in
            *404*) fail "arch=$arch builder_image references $image — package '$pkg' does not exist on GHCR. Either republish it or fix cloud-data-runners.json"; continue ;;
        esac
        fail "arch=$arch: gh API error for $pkg"
        continue
    }
    vis=$(echo "$body" | jq -r '.visibility // empty')
    if [ "$vis" != "public" ]; then
        fail "arch=$arch builder_image $image — package '$pkg' is $vis (must be public so anonymous docker pull on oci-apps works)"
    else
        pass "arch=$arch → $image (public)"
        CHECKED=$((CHECKED + 1))
    fi
done < <(jq -r '.runners | to_entries[] | select(.value.type == "ssh" and .value.builder_image) | "\(.key)\t\(.value.builder_image)"' "$RUNNERS_JSON")

if [ "$FAIL" -eq 0 ]; then
    echo ""
    echo "Phase 17 runners image: PASS ($CHECKED ssh-runner image(s))"
    exit 0
else
    echo ""
    echo "Phase 17 runners image: FAIL"
    exit 1
fi
