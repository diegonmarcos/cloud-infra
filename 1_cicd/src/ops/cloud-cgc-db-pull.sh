#!/bin/sh
# ──────────────────────────────────────────────────────────────────────────
#  cloud-cgc-db-pull.sh — restore the cloud-cgc octocode DB FROM GHCR (consumer)
# ──────────────────────────────────────────────────────────────────────────
#  GHCR is the SINGLE upstream. Both consumers use this same script so local and
#  oci-apps always run an identical DB:
#    - local:    target = ~/.local/share/octocode   (cloud-cgc-pub-mcp-local)
#    - oci-apps: target = the octocode_db volume mount (Dagu ops_octocode-db-pull)
#  Data-driven: image/tag come from build.json `.db_publish`. Never hardcoded.
#
#  Args: optional $1 = target octocode home (default: $OCTOCODE_HOME or
#        ~/.local/share/octocode). Idempotent; no-op (exit 0) if GHCR has no
#        image yet (producer must seed it once first).
#
#  Optional $2 (or env CGC_PULL_IMAGE) = "image[:tag]" to restore INSTEAD of
#  the monolith db_publish.image — used by per-repo matrix CI to restore the
#  shared base (per_repo_publish.base_image) or one repo's own checkpoint
#  image (per_repo_publish.image_prefix<repo>) into the SAME fresh home.
#
#  Optional env CGC_PULL_MERGE=1 skips the clean-wipe of $TARGET before
#  extracting — layers this pull ON TOP of what is already there instead of
#  replacing it. Matrix CI restores base (clean) THEN the repo's own image
#  (merge) into one fresh home; a plain monolith pull always stays clean.
# ──────────────────────────────────────────────────────────────────────────
set -eu
ROOT="${CLOUD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
BJ="${CGC_BUILD_JSON:-$ROOT/a_solutions/user-ai_cloud-cgc-pub-mcp/build.json}"
[ -f "$BJ" ] || { echo "::error::cloud-cgc-pub-mcp build.json not found at $BJ"; exit 1; }

TARGET="${1:-${OCTOCODE_HOME:-$HOME/.local/share/octocode}}"
IMAGE_ARG="${2:-${CGC_PULL_IMAGE:-}}"
if [ -n "$IMAGE_ARG" ]; then
  IMAGE="${IMAGE_ARG%:*}"
  case "$IMAGE_ARG" in *:*) TAG="${IMAGE_ARG##*:}" ;; *) TAG="latest" ;; esac
else
  IMAGE=$(jq -r '.db_publish.image' "$BJ")
  TAG=$(jq -r '.db_publish.tag // "latest"' "$BJ")
fi

echo "[cgc-db] pull $IMAGE:$TAG → $TARGET"
if ! docker manifest inspect "$IMAGE:$TAG" >/dev/null 2>&1; then
  echo "::warning::$IMAGE:$TAG not on GHCR yet — nothing to restore (producer ship-cgc-db must seed it first)"
  exit 0
fi
docker pull -q "$IMAGE:$TAG" >/dev/null
CID=$(docker create "$IMAGE:$TAG")
trap 'docker rm -f "$CID" >/dev/null 2>&1 || true' EXIT
mkdir -p "$TARGET"
# Clean restore, not merge: clear the target first so stale project-hash dirs and
# deleted-file embeddings from a previous DB don't linger and shadow the new graph
# (GHCR is the single upstream — the target must MIRROR it, not accumulate). $TARGET
# is always set (set -u + default above); we only clear its contents, never itself.
# CGC_PULL_MERGE=1 skips this wipe — matrix CI restores the shared base image
# (clean) first, then this repo's own checkpoint image on top (merge); wiping on
# the second pull would erase the base's config.toml/fastembed caches just restored.
if [ "${CGC_PULL_MERGE:-}" != "1" ]; then
  rm -rf "$TARGET"/* "$TARGET"/.[!.]* 2>/dev/null || true
fi
docker cp "$CID:/octocode-db/." "$TARGET/"
echo "[cgc-db] restored DB into $TARGET ($(du -sh "$TARGET" 2>/dev/null | cut -f1))"
# Drop the transport image the moment its contents are on disk. It is pure dead weight
# after the cp — nothing reads it again — but at ~15G it was pinning a second full copy
# of the DB in docker storage for the WHOLE run, on top of the extracted copy. That is
# what starved the per-repo checkpoints on 2026-08-21: front-data published fine, then
# cloud-android's build died with "no space left on device" after disk fell 54G -> 24G
# -> 10G. Freeing it here is worth ~15G and costs nothing, since a later checkpoint
# rebuilds the image from the extracted DB rather than from this one. Non-fatal: the
# container is removed by the EXIT trap regardless, and a failed rmi only wastes space.
docker rm -f "$CID" >/dev/null 2>&1 || true
docker rmi "$IMAGE:$TAG" >/dev/null 2>&1 \
  && echo "[cgc-db] freed transport image $IMAGE:$TAG ($(df -Pk "$TARGET" 2>/dev/null | awk 'NR==2{printf "%.0fG free", $4/1048576}'))" \
  || true
