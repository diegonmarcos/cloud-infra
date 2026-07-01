#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_workflows/src/scripts/cloud-cgc-db-package.sh
# ║   Engine : 1_workflows/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ──────────────────────────────────────────────────────────────────────────
#  cloud-cgc-db-package.sh — package an octocode DB directory → GHCR image + push
# ──────────────────────────────────────────────────────────────────────────
#  Packaging path used by cloud-cgc-db-update.sh (producer: local octocode home
#  → GHCR). GHCR is the single upstream for the cloud-cgc octocode DB (semantic
#  FastEmbed vectors + GraphRAG graph). Both consumers (oci-apps arm via the
#  ops_octocode-db-pull DAG, and local) pull it back with cloud-cgc-db-pull.sh.
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
# DOCKER_BUILDKIT=0 (legacy builder) for this trivial busybox+ADD image: buildx
# tries to chown ~/.docker/buildx/activity/default, which fails when the producer
# runs inside the freeze-proof scope with egid=docker (non-primary group) →
# "operation not permitted". The legacy builder never touches that dir. The image
# is a one-line FROM/ADD, so BuildKit features are irrelevant here.
DOCKER_BUILDKIT=0 docker build -t "$IMAGE:$TAG" "$WORK/ctx"
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
