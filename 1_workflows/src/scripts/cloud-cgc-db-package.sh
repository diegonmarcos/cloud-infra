#!/bin/sh
# ──────────────────────────────────────────────────────────────────────────
#  cloud-cgc-db-package.sh — package an octocode DB directory → GHCR image + push
# ──────────────────────────────────────────────────────────────────────────
#  Shared packaging path (DRY) for BOTH:
#    - cloud-cgc-db-update.sh  (producer: local octocode home → GHCR)
#    - cloud-kg-db-snapshot.sh (durability: oci-apps octocode_db volume → GHCR)
#  GHCR is the single upstream for the cloud-cgc octocode DB (semantic FastEmbed
#  vectors + GraphRAG graph). Both consumers (oci-apps arm, local) pull it back.
#
#  Args: $1=SRC_DIR (octocode home contents)  $2=IMAGE (ghcr.io/...)  $3=TAG
# ──────────────────────────────────────────────────────────────────────────
set -eu
SRC="${1:?usage: cloud-cgc-db-package.sh <src_dir> <image> [tag]}"
IMAGE="${2:?image required}"
TAG="${3:-latest}"
PKG="${IMAGE##*/}"
[ -d "$SRC" ] || { echo "::error::src dir not found: $SRC"; exit 1; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/ctx"
tar cf "$WORK/ctx/octocode-db.tar" -C "$SRC" .
[ -s "$WORK/ctx/octocode-db.tar" ] || { echo "::error::empty DB tar from $SRC"; exit 1; }
echo "[cgc-db] packaged $(du -h "$WORK/ctx/octocode-db.tar" | cut -f1) from $SRC"

# Minimal image: ADD auto-extracts the tar to /octocode-db. Restored by
# cloud-cgc-db-pull.sh (docker cp /octocode-db/. → octocode home / volume).
cat > "$WORK/ctx/Dockerfile" <<'DOCKER'
FROM busybox:latest
ADD octocode-db.tar /octocode-db
LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
LABEL org.opencontainers.image.description="cloud-cgc-mcp octocode DB (semantic FastEmbed vectors + GraphRAG graph). Single GHCR upstream; restore into the octocode home (~/.local/share/octocode or the octocode_db volume) via cloud-cgc-db-pull.sh."
DOCKER

echo "[cgc-db] building $IMAGE:$TAG ..."
docker build -t "$IMAGE:$TAG" "$WORK/ctx"
echo "[cgc-db] pushing $IMAGE:$TAG ..."
docker push "$IMAGE:$TAG"

# Flip the package public (pull convenience). Non-fatal — push already succeeded.
if command -v gh >/dev/null 2>&1; then
  vis=$(gh api "/user/packages/container/${PKG}" --jq '.visibility' 2>/dev/null || echo unknown)
  if [ "$vis" != "public" ]; then
    gh api --method PUT "/user/packages/container/${PKG}/visibility" -f visibility=public >/dev/null 2>&1 \
      && echo "[cgc-db] $PKG → public" \
      || echo "::warning::could not flip $PKG public (needs packages-admin token or the GitHub UI)"
  else
    echo "[cgc-db] package $PKG already public"
  fi
fi
echo "[cgc-db] DONE → $IMAGE:$TAG"
