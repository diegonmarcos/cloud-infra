#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 16 tester — every compose.nix `binariesImage` reference    ║
# ║ MUST resolve to a real GHCR package after deploy.                ║
# ║                                                                  ║
# ║ Convention (declared in _shared/engine.nix manifest schema):     ║
# ║   compose layer references ghcr.io/diegonmarcos/<name>-binaries  ║
# ║   The engine MUST push BOTH `<name>:latest` AND                  ║
# ║   `<name>-binaries:latest` so docker compose pull on VM works.   ║
# ║                                                                  ║
# ║ Without this match: first-ever ship of any v2 service hits       ║
# ║ "denied: denied" pulling the missing -binaries image.            ║
# ║                                                                  ║
# ║ Data-driven (FIRE RULE 3): walks every build.json with           ║
# ║ docker.image set, checks both packages on GHCR. Skipped when     ║
# ║ gh is unauthenticated (local dev) or if the service has not yet  ║
# ║ been deployed (binaries pkg may not yet exist for new services). ║
# ║                                                                  ║
# ║ Usage:                                                           ║
# ║   bash 1_configs/src/deploy/test/test_binaries_image_published.sh     ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

# Repo root by upward search, not a fixed ../../.. — this file exists at BOTH
# 1_configs/src/deploy/test/ and 1_configs/dist/test/ (generated), which sit at
# different depths, so one literal count is wrong for one of the two copies.
REPO_ROOT="$(_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
warn() { printf "  ! %s\n" "$1" >&2; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── For every declared docker.image, both <name> and <name>-binaries must exist on GHCR ──"

if ! command -v gh >/dev/null 2>&1; then
    echo "  ⚠ gh CLI not installed — skipping (not a failure)"
    exit 0
fi
if ! gh auth status >/dev/null 2>&1; then
    echo "  ⚠ gh not authenticated — skipping (not a failure)"
    exit 0
fi

_pkg_visibility() {
    # Returns "public", "private", "absent" (404), or empty on other error.
    local pkg="$1"
    local body http
    body=$(gh api "/user/packages/container/$pkg" 2>/dev/null) || {
        http=$(gh api -i "/user/packages/container/$pkg" 2>/dev/null | head -1 || echo "")
        case "$http" in *404*) echo "absent"; return 0 ;; esac
        return 1
    }
    echo "$body" | jq -r '.visibility // empty'
}

CHECKED=0
NEW_SERVICES=0
SKIPPED_COMPOSE_BUILD=0
while IFS= read -r build_json; do
    image=$(jq -r '.docker.image // empty' "$build_json" 2>/dev/null)
    registry=$(jq -r '.docker.registry // empty' "$build_json" 2>/dev/null)
    [ -z "$image" ] && continue
    [ "$registry" != "ghcr.io/diegonmarcos" ] && continue

    # Filter out compose-build services. step_docker (cloud-ship-container-
    # step-build-docker.sh:220-223) skips when there's no src/Dockerfile and
    # no docker.native_build.cmd — those services use dockerfile_inline in
    # compose, so docker-compose builds the image at deploy time on the VM.
    # They never ship a -binaries package to GHCR by design; the compose
    # `image:` ref serves as a tag for the locally-built image, not a pull
    # target. Without this filter the test over-reaches and reports 40+
    # false positives. Match the engine's skip predicate exactly.
    svc_dir=$(dirname "$build_json")
    has_dockerfile=0
    [ -f "$svc_dir/src/Dockerfile" ] && has_dockerfile=1
    native_cmd=$(jq -r '.docker.native_build.cmd // empty' "$build_json" 2>/dev/null)
    if [ "$has_dockerfile" = 0 ] && [ -z "$native_cmd" ]; then
        SKIPPED_COMPOSE_BUILD=$((SKIPPED_COMPOSE_BUILD + 1))
        continue
    fi

    primary_vis=$(_pkg_visibility "$image" || echo "")
    binaries_vis=$(_pkg_visibility "${image}-binaries" || echo "")

    case "$primary_vis" in
        public)
            case "$binaries_vis" in
                public)
                    pass "$image (both public)"
                    CHECKED=$((CHECKED + 1))
                    ;;
                private|internal)
                    fail "$image: -binaries package is $binaries_vis — flip via: gh api --method PUT /user/packages/container/${image}-binaries/visibility -f visibility=public"
                    ;;
                absent)
                    fail "$image: published, but ${image}-binaries is MISSING — engine must push both tags (cloud-ship-container-step-build-docker.sh)"
                    ;;
                *)
                    warn "$image: -binaries visibility check failed (skipped)"
                    ;;
            esac
            ;;
        absent)
            warn "$image: never published — service may be new/unpushed (no fail)"
            NEW_SERVICES=$((NEW_SERVICES + 1))
            ;;
        private|internal)
            fail "$image: primary package is $primary_vis (should be public)"
            ;;
        *)
            warn "$image: visibility check failed (skipped)"
            ;;
    esac
done < <(find "$REPO_ROOT/a_solutions" -maxdepth 2 -name build.json -not -path "*/z_archive/*" 2>/dev/null)

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "Phase 16 binaries image: PASS ($CHECKED services with both tags public; $NEW_SERVICES new/unpushed; $SKIPPED_COMPOSE_BUILD compose-build skipped)"
    exit 0
else
    echo "Phase 16 binaries image: FAIL ($CHECKED checked; $SKIPPED_COMPOSE_BUILD compose-build skipped)"
    exit 1
fi
