#!/bin/sh
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

# Reclaim disk BEFORE building. The DB image is ~1.6GB and the deploy host's docker
# data-root runs hot (observed oci-apps: 88% full, 14GB reclaimable). Every rebuild of
# :latest orphans the PREVIOUS version as a dangling (untagged) image; nothing GC's them,
# so they pile up until `docker build` dies mid-layer with
#   "failed to get digest sha256:… : … no such file or directory"
# (an image-store write failure under disk pressure — exactly how run 28665357140 failed).
# Prune dangling images only: they are untagged/superseded and reproducible from GHCR;
# running services use TAGGED images + volumes, which prune never touches. Non-fatal.
if command -v docker >/dev/null 2>&1; then
  _free_before=$(df -Pk /var/lib/docker 2>/dev/null | awk 'NR==2{print $4}')
  docker image prune -f >/dev/null 2>&1 || true
  _free_after=$(df -Pk /var/lib/docker 2>/dev/null | awk 'NR==2{print $4}')
  echo "[cgc-db] pruned dangling images — free KB ${_free_before:-?} -> ${_free_after:-?}"
fi

echo "[cgc-db] building $IMAGE:$TAG ..."
# DOCKER_BUILDKIT=0 (legacy builder) for this trivial busybox+ADD image: buildx
# tries to chown ~/.docker/buildx/activity/default, which fails when the producer
# runs inside the freeze-proof scope with egid=docker (non-primary group) →
# "operation not permitted". The legacy builder never touches that dir. The image
# is a one-line FROM/ADD, so BuildKit features are irrelevant here.
DOCKER_BUILDKIT=0 docker build -t "$IMAGE:$TAG" "$WORK/ctx"
echo "[cgc-db] pushing $IMAGE:$TAG ..."
docker push "$IMAGE:$TAG"
# Drop the local tagged copy after a successful push — GHCR is the single store, and
# keeping it locally just re-fills the data-root every run. Next run rebuilds trivially.
docker rmi "$IMAGE:$TAG" >/dev/null 2>&1 || true

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
