#!/bin/sh
# ──────────────────────────────────────────────────────────────────────────
#  cloud-cgc-db-pull.sh — restore the cloud-cgc octocode DB FROM GHCR (consumer)
# ──────────────────────────────────────────────────────────────────────────
#  GHCR is the SINGLE upstream. Both consumers use this same script so local and
#  oci-apps always run an identical DB:
#    - local:    target = ~/.local/share/octocode   (cloud-cgc-mcp-local)
#    - oci-apps: target = the octocode_db volume mount (Dagu ops_octocode-db-pull)
#  Data-driven: image/tag come from build.json `.db_publish`. Never hardcoded.
#
#  Args: optional $1 = target octocode home (default: $OCTOCODE_HOME or
#        ~/.local/share/octocode). Idempotent; no-op (exit 0) if GHCR has no
#        image yet (producer must seed it once first).
# ──────────────────────────────────────────────────────────────────────────
set -eu
ROOT="${CLOUD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
BJ="${CGC_BUILD_JSON:-$ROOT/a_solutions/user-ai_cloud-cgc-mcp/build.json}"
[ -f "$BJ" ] || { echo "::error::cloud-cgc-mcp build.json not found at $BJ"; exit 1; }

IMAGE=$(jq -r '.db_publish.image' "$BJ")
TAG=$(jq -r '.db_publish.tag // "latest"' "$BJ")
TARGET="${1:-${OCTOCODE_HOME:-$HOME/.local/share/octocode}}"

echo "[cgc-db] pull $IMAGE:$TAG → $TARGET"
if ! docker manifest inspect "$IMAGE:$TAG" >/dev/null 2>&1; then
  echo "::warning::$IMAGE:$TAG not on GHCR yet — nothing to restore (producer ship-cgc-db must seed it first)"
  exit 0
fi
docker pull -q "$IMAGE:$TAG" >/dev/null
CID=$(docker create "$IMAGE:$TAG")
trap 'docker rm -f "$CID" >/dev/null 2>&1 || true' EXIT
mkdir -p "$TARGET"
docker cp "$CID:/octocode-db/." "$TARGET/"
echo "[cgc-db] restored DB into $TARGET ($(du -sh "$TARGET" 2>/dev/null | cut -f1))"
