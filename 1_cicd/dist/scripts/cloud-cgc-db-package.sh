#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_cicd/src/ops/cloud-cgc-db-package.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
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
LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud-infra"
LABEL org.opencontainers.image.description="cloud-cgc-mcp octocode DB (semantic FastEmbed vectors + GraphRAG graph). Single GHCR upstream; restore into the octocode home (~/.local/share/octocode or the octocode_db volume) via cloud-cgc-db-pull.sh."
DOCKER

# Reclaim disk BEFORE building. NOTE the size below is badly stale: the DB image was
# ~1.6GB when this was written and is ~15G as of 2026-08-21 (du -sh of the octocode home
# reports 16G). At that size the old "prune dangling images" step is no longer sufficient
# on a CI runner, because BuildKit's build cache also retains a full copy of the 15G layer
# and `docker image prune` does not touch it. Per-repo checkpointing then compounds it:
# each checkpoint writes a 15G context tar AND a 15G image, so the second checkpoint of a
# run hit "no space left on device" even with 26G free after a prune. Prune the builder
# cache too — it is reproducible by definition and nothing depends on it surviving.
# The DB image is ~1.6GB and the deploy host's docker
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
  # BuildKit cache holds its own copy of the 15G layer and survives `image prune`; with a
  # DB this size that cache alone is the difference between a checkpoint fitting and not.
  docker builder prune -af >/dev/null 2>&1 || true
  _free_after=$(df -Pk /var/lib/docker 2>/dev/null | awk 'NR==2{print $4}')
  echo "[cgc-db] pruned dangling images + builder cache — free KB ${_free_before:-?} -> ${_free_after:-?}"
fi

echo "[cgc-db] building $IMAGE:$TAG ..."
# BuildKit with an ISOLATED DOCKER_CONFIG. The legacy builder (DOCKER_BUILDKIT=0)
# is NOT crash-safe on the shared oci-apps daemon: its parent-chain image store
# corrupts under concurrent image ops — observed as both
#   "failed to set parent sha256:…: unknown parent image ID"        (runs 28731867216, 28844070303)
#   "failed to get digest sha256:…: imagedb/content/…: no such file" (run 28665357140)
# BuildKit never touches that legacy store. The reason legacy was used before —
# buildx chowns ~/.docker/buildx/activity, which fails inside the freeze-proof
# scope (egid=docker, non-primary group) — is solved by pointing DOCKER_CONFIG at
# a fresh temp dir owned by THIS process. Auth is irrelevant for the build (the
# busybox base is a public pull); the push below uses the normally-authed config.
mkdir -p "$WORK/dcfg"
DOCKER_CONFIG="$WORK/dcfg" docker build -t "$IMAGE:$TAG" "$WORK/ctx"
# Free the context tar the INSTANT the build no longer needs it. It is ~15G and the EXIT
# trap only fires when this script ends, so it was otherwise held through the whole push
# and into the next repo's index — one of three simultaneous 15G copies (DB + tar + image)
# that made checkpoint #3 fail with "no space left on device" on 2026-08-21.
rm -f "$WORK/ctx/octocode-db.tar" 2>/dev/null || true
echo "[cgc-db] pushing $IMAGE:$TAG ..."
docker push "$IMAGE:$TAG"
# Drop the local tagged copy after a successful push — GHCR is the single store, and
# keeping it locally just re-fills the data-root every run. Next run rebuilds trivially.
docker rmi "$IMAGE:$TAG" >/dev/null 2>&1 || true
# Release THIS build's BuildKit cache now rather than at the next checkpoint. Note the
# DOCKER_CONFIG: the build above runs with a per-invocation config dir, so a prune without
# it addresses different builder state — which is exactly why the pre-build prune on
# 2026-08-21 reported "free KB 25939472 -> 25939468", reclaiming 4KB of a 15G cache while
# the checkpoint that followed died for want of space. Same config in, space actually out.
if command -v docker >/dev/null 2>&1; then
  _fb=$(df -Pk /var/lib/docker 2>/dev/null | awk 'NR==2{print $4}')
  DOCKER_CONFIG="$WORK/dcfg" docker builder prune -af >/dev/null 2>&1 || true
  docker image prune -f >/dev/null 2>&1 || true
  _fa=$(df -Pk /var/lib/docker 2>/dev/null | awk 'NR==2{print $4}')
  echo "[cgc-db] post-push reclaim — free KB ${_fb:-?} -> ${_fa:-?}"
fi

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
