#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 3D tester — chat-mattermost arm64 build invariants         ║
# ║                                                                  ║
# ║ Proves the service uses our in-house arm64 build path:           ║
# ║   1. No reference to ngrie/mattermost-team-edition-arm           ║
# ║      (community fork; only publishes amd64; broke oci-apps).     ║
# ║   2. No reference to upstream mattermost/mattermost-team-edition ║
# ║      Docker image (still amd64-only on Docker Hub for 11.x).     ║
# ║   3. A vendored Dockerfile exists at src/code/arm64/Dockerfile   ║
# ║      with the UPSTREAM.txt pin metadata next to it.              ║
# ║   4. build.json#docker.build_args.MM_PACKAGE points at the       ║
# ║      official releases.mattermost.com URL with a -linux-arm64    ║
# ║      .tar.gz suffix (so cloud-builder builds with the right      ║
# ║      binary tarball).                                            ║
# ║                                                                  ║
# ║ Strategy: static check (no network). The actual build happens    ║
# ║ on oci-apps cloud-builder via the ship pipeline; this test       ║
# ║ catches accidental regressions in the source declarations.       ║
# ║                                                                  ║
# ║ Usage: bash 1_workflows/src/test/test_mattermost_multiarch.sh    ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SVC_DIR="$REPO_ROOT/a_solutions/aa-sui_chat-mattermost"
FLAKE="$SVC_DIR/src/flake.nix"
DOCKERFILE="$SVC_DIR/src/code/arm64/Dockerfile"
UPSTREAM_PIN="$SVC_DIR/src/code/arm64/UPSTREAM.txt"
BUILD_JSON="$SVC_DIR/build.json"

# -L follows symlinks (build-*.json files are symlinks to ../../../2_configs/dist/)
SEARCH_FILES=$(find -L "$SVC_DIR/src" -maxdepth 2 -type f \
    \( -name 'flake.nix' -o -name 'build-*.json' -o -name 'build.json' -o -name 'compose.nix' \) 2>/dev/null)

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── chat-mattermost arm64 build invariants ──"

# (1) No ngrie fork
if grep -nE 'ngrie/mattermost-team-edition-arm' $SEARCH_FILES 2>/dev/null \
    | grep -vE ':\s*(#|//)' \
    | grep -q .; then
    fail "source still references ngrie/mattermost-team-edition-arm (amd64-only, breaks oci-apps):"
    grep -nE 'ngrie/mattermost-team-edition-arm' $SEARCH_FILES \
        | grep -vE ':\s*(#|//)' >&2 || true
else
    pass "no reference to ngrie fork in code"
fi

# (2) No upstream mattermost/mattermost-team-edition image (we vendor the
# Dockerfile and build our own arm64 image from the binary tarball)
if grep -nE 'mattermost/mattermost-team-edition' $SEARCH_FILES 2>/dev/null \
    | grep -vE ':\s*(#|//)' \
    | grep -q .; then
    fail "source still references upstream mattermost/mattermost-team-edition Docker image (amd64-only on Docker Hub):"
    grep -nE 'mattermost/mattermost-team-edition' $SEARCH_FILES \
        | grep -vE ':\s*(#|//)' >&2 || true
else
    pass "no reference to upstream amd64-only Docker image"
fi

# (3) Vendored upstream Dockerfile + pin metadata exist
if [ -f "$DOCKERFILE" ]; then
    pass "vendored Dockerfile exists ($DOCKERFILE)"
else
    fail "vendored Dockerfile missing at $DOCKERFILE"
fi
if [ -f "$UPSTREAM_PIN" ] && grep -q '^commit_sha:' "$UPSTREAM_PIN" 2>/dev/null; then
    pass "UPSTREAM.txt pin records commit_sha"
else
    fail "UPSTREAM.txt missing or lacks commit_sha at $UPSTREAM_PIN"
fi

# (4) build.json declares MM_PACKAGE → arm64 tarball
MM_PACKAGE=$(jq -r '.docker.build_args.MM_PACKAGE // empty' "$BUILD_JSON" 2>/dev/null)
if [ -z "$MM_PACKAGE" ]; then
    fail "build.json#docker.build_args.MM_PACKAGE not set — build will pull amd64 default"
elif [[ "$MM_PACKAGE" != *"releases.mattermost.com"* ]]; then
    fail "MM_PACKAGE is not a releases.mattermost.com URL: $MM_PACKAGE"
elif [[ "$MM_PACKAGE" != *"-linux-arm64.tar.gz" ]]; then
    fail "MM_PACKAGE does not end with -linux-arm64.tar.gz: $MM_PACKAGE"
else
    pass "MM_PACKAGE → $MM_PACKAGE"
fi

# (5) Agents plugin pinned to an arm64 tarball — TE ships zero plugins so
# this URL is the only way the Agents plugin actually lands in the image.
MM_PLUGIN_AGENTS_URL=$(jq -r '.docker.build_args.MM_PLUGIN_AGENTS_URL // empty' "$BUILD_JSON" 2>/dev/null)
if [ -z "$MM_PLUGIN_AGENTS_URL" ]; then
    fail "build.json#docker.build_args.MM_PLUGIN_AGENTS_URL not set — Agents plugin won't be baked into the image and /api/v4/plugins will return empty"
elif [[ "$MM_PLUGIN_AGENTS_URL" != *"mattermost-plugin-agents"* ]]; then
    fail "MM_PLUGIN_AGENTS_URL doesn't look like a mattermost-plugin-agents release: $MM_PLUGIN_AGENTS_URL"
elif [[ "$MM_PLUGIN_AGENTS_URL" != *"-linux-arm64.tar.gz" ]]; then
    fail "MM_PLUGIN_AGENTS_URL is not an arm64 build: $MM_PLUGIN_AGENTS_URL"
else
    pass "MM_PLUGIN_AGENTS_URL → $MM_PLUGIN_AGENTS_URL"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "══════════════════════════════════════════════"
    echo "Phase 3D chat-mattermost arm64 invariants: PASS"
    echo "══════════════════════════════════════════════"
    exit 0
else
    echo "══════════════════════════════════════════════"
    echo "Phase 3D chat-mattermost arm64 invariants: FAIL"
    echo "══════════════════════════════════════════════"
    exit 1
fi
