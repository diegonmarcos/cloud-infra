#!/bin/sh
# ──────────────────────────────────────────────────────────────────────────
#  cloud-kg-db-snapshot.sh — publish the kg-mcp octocode GraphRAG DB to GHCR
# ──────────────────────────────────────────────────────────────────────────
#  The live GraphRAG index (FastEmbed vectors + the LLM relationship graph,
#  the expensive multi-hour build) lives ONLY in the `octocode_db` Docker
#  volume on oci-apps. A volume wipe loses it. This snapshots that volume into
#  a GHCR image so it is durable + reproducible: a fresh deploy can restore the
#  whole graph by pulling the image instead of re-indexing for hours.
#
#  Thin-wrapper philosophy: ALL logic is here (POSIX); the GHA workflow only
#  provides the runtime (WG up, target-host SSH alias configured, `docker login
#  ghcr.io` + `gh` authed). Runs identically from GHA, Dagu, or a CLI that has
#  those prerequisites.
#
#  Why GHA (not the local/VM ship): GHCR packages are made PUBLIC here via the
#  `gh` visibility API — the local ship's PAT lacks that scope (it warns
#  "could not flip to public"); the GHA token has it.
#
#  Config is data-driven from kg-mcp build.json `.db_publish` — never hardcoded.
# ──────────────────────────────────────────────────────────────────────────
set -eu

ROOT="${CLOUD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
BJ="${KG_BUILD_JSON:-$ROOT/a_solutions/user-ai_kg-mcp/build.json}"
[ -f "$BJ" ] || { echo "::error::kg-mcp build.json not found at $BJ"; exit 1; }

IMAGE=$(jq -r '.db_publish.image'        "$BJ")
TAG=$(jq -r   '.db_publish.tag // "latest"' "$BJ")
VOLUME=$(jq -r '.db_publish.volume'      "$BJ")
HOST=$(jq -r  '.db_publish.host'         "$BJ")   # ssh alias, configured by the caller
[ "$IMAGE" != "null" ] && [ "$VOLUME" != "null" ] && [ "$HOST" != "null" ] || {
  echo "::error::db_publish.{image,volume,host} missing in $BJ"; exit 1; }
PKG="${IMAGE##*/}"   # package name for the gh visibility API

echo "[kg-db] snapshot volume '$VOLUME' on '$HOST' → $IMAGE:$TAG"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/ctx"

# Stream the volume contents as a tar from the remote host. busybox is always
# pullable; the volume is mounted :ro so the live MCP is undisturbed. The DB is
# the octocode Lance tables (graphrag_nodes/relationships, embeddings) + config.
echo "[kg-db] streaming volume tar from $HOST ..."
ssh "$HOST" "docker run --rm -v ${VOLUME}:/db:ro busybox tar cf - -C /db ." > "$WORK/ctx/octocode-db.tar"
[ -s "$WORK/ctx/octocode-db.tar" ] || { echo "::error::empty tar from $HOST:$VOLUME"; exit 1; }
echo "[kg-db] received $(du -h "$WORK/ctx/octocode-db.tar" | cut -f1) tar"

# Minimal image: ADD auto-extracts the tar to /octocode-db. Restore by mounting
# this image's /octocode-db into the octocode_db volume (init container or
# `docker cp`) before kg-mcp starts.
cat > "$WORK/ctx/Dockerfile" <<'DOCKER'
FROM busybox:latest
ADD octocode-db.tar /octocode-db
LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
LABEL org.opencontainers.image.description="kg-mcp octocode GraphRAG index snapshot (FastEmbed vectors + LLM relationship graph) — restore into the octocode_db volume"
DOCKER

echo "[kg-db] building $IMAGE:$TAG ..."
docker build -t "$IMAGE:$TAG" "$WORK/ctx"
echo "[kg-db] pushing $IMAGE:$TAG ..."
docker push "$IMAGE:$TAG"

# Flip the package public — reuse the engine's exact mechanism
# (cloud-ship-container-step-build-docker.sh:918). Non-fatal: the push already
# succeeded; public is a pull convenience.
if command -v gh >/dev/null 2>&1; then
  vis=$(gh api "/user/packages/container/${PKG}" --jq '.visibility' 2>/dev/null || echo unknown)
  if [ "$vis" != "public" ]; then
    echo "[kg-db] package $PKG: $vis — flipping to public"
    gh api --method PUT "/user/packages/container/${PKG}/visibility" -f visibility=public >/dev/null 2>&1 \
      && echo "[kg-db] $PKG → public" \
      || echo "::warning::could not flip $PKG public (needs a token with packages admin, or the GitHub UI)"
  else
    echo "[kg-db] package $PKG already public"
  fi
fi
echo "[kg-db] DONE → $IMAGE:$TAG"
