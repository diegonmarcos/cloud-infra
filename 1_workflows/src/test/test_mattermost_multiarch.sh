#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 3D tester — mattermost base image is multi-arch            ║
# ║                                                                  ║
# ║ Proves:                                                          ║
# ║   chat-mattermost/flake.nix uses an upstream image that          ║
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
SVC_DIR="$REPO_ROOT/a_solutions/aa-sui_chat-mattermost"
FLAKE="$SVC_DIR/src/flake.nix"
# Image declaration now lives in auto-generated build-mattermost.json (derived
# from cloud-data-consolidated); flake.nix just readFile's it. Assert on the
# full set of source files that could carry the image reference.
# -L follows symlinks (build-*.json files are symlinks to ../../../2_configs/dist/)
SEARCH_FILES=$(find -L "$SVC_DIR/src" -maxdepth 2 -type f \
    \( -name 'flake.nix' -o -name 'build-*.json' -o -name 'build.json' -o -name 'compose.nix' \) 2>/dev/null)

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── chat-mattermost base image ──"

if [ -z "$SEARCH_FILES" ]; then
    fail "no flake.nix / build-*.json found under $SVC_DIR/src"
else
    # The forbidden fork tag — ngrie/mattermost-team-edition-arm only publishes
    # amd64. Match executable code only (skip '#'- and '//'-comment lines so the
    # swap note explaining WHY we switched doesn't trip the test).
    if grep -nE 'ngrie/mattermost-team-edition-arm' $SEARCH_FILES 2>/dev/null \
        | grep -vE ':\s*(#|//)' \
        | grep -q .; then
        fail "source still references ngrie/mattermost-team-edition-arm (amd64-only, breaks oci-apps):"
        grep -nE 'ngrie/mattermost-team-edition-arm' $SEARCH_FILES \
            | grep -vE ':\s*(#|//)' >&2 || true
    else
        pass "no reference to ngrie fork in code"
    fi

    if grep -qE 'mattermost/mattermost-team-edition:[0-9]' $SEARCH_FILES; then
        pass "source declares upstream multi-arch mattermost/mattermost-team-edition"
    else
        fail "source does not reference upstream mattermost/mattermost-team-edition — cannot guarantee multi-arch"
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
