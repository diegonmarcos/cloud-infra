#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 3D tester — mattermost base image is multi-arch            ║
# ║                                                                  ║
# ║ Proves:                                                          ║
# ║   mattermost-bots/flake.nix uses an upstream image that          ║
# ║   publishes both linux/amd64 and linux/arm64 manifests.          ║
# ║   The old ngrie/mattermost-team-edition-arm fork only publishes  ║
# ║   amd64, breaking oci-apps (aarch64).                            ║
# ║                                                                  ║
# ║ Strategy: static check of flake source (no network). The full    ║
# ║ manifest check is run in the weekly sweep preflight via          ║
# ║ `docker manifest inspect`.                                        ║
# ║                                                                  ║
# ║ Usage: bash 1_workflows/src/test/test_mattermost_multiarch.sh    ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
FLAKE="$REPO_ROOT/a_solutions/aa-sui_mattermost-bots/src/flake.nix"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── mattermost-bots base image ──"

if [ ! -f "$FLAKE" ]; then
    fail "flake.nix not found at $FLAKE"
else
    # The forbidden fork tag — ngrie/mattermost-team-edition-arm only publishes
    # amd64. Match executable code only (skip '#'-comment lines so the swap
    # note in flake.nix explaining WHY we switched doesn't trip the test).
    if grep -nE 'ngrie/mattermost-team-edition-arm' "$FLAKE" \
        | grep -vE '^\s*[0-9]+:\s*#' \
        | grep -q .; then
        fail "flake.nix still references ngrie/mattermost-team-edition-arm (amd64-only, breaks oci-apps):"
        grep -nE 'ngrie/mattermost-team-edition-arm' "$FLAKE" \
            | grep -vE '^\s*[0-9]+:\s*#' >&2 || true
    else
        pass "flake.nix does not reference the ngrie fork in code"
    fi

    if grep -qE 'mattermost/mattermost-team-edition:[0-9]' "$FLAKE"; then
        pass "flake.nix uses upstream multi-arch mattermost/mattermost-team-edition"
    else
        fail "flake.nix does not reference upstream mattermost/mattermost-team-edition — cannot guarantee multi-arch"
    fi
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "══════════════════════════════════════════════"
    echo "Phase 3D mattermost multi-arch: PASS"
    echo "══════════════════════════════════════════════"
    exit 0
else
    echo "══════════════════════════════════════════════"
    echo "Phase 3D mattermost multi-arch: FAIL"
    echo "══════════════════════════════════════════════"
    exit 1
fi
