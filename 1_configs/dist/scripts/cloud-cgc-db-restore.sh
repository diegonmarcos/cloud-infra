#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/deploy/scripts/cloud-cgc-db-restore.sh
# ║   Engine : 1_configs/src/deploy/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ──────────────────────────────────────────────────────────────────────────
#  cloud-cgc-db-restore.sh — restore the cloud-cgc octocode DB FROM GHCR (arm consumer)
# ──────────────────────────────────────────────────────────────────────────
#  Universal restore routine, runs ON the target host (oci-apps): pull the GHCR
#  DB image → copy it into the octocode_db volume → restart cloud-cgc-mcp →
#  notify. The Dagu DAG carries ZERO logic — it only deploys this script (via
#  vm-pilot to /opt/scripts) and TRIGGERS it over SSH.
#
#  Config from env (the DAG passes these, mirroring build.json — the VM has no
#  repo checkout), with build.json fallback when CGC_BUILD_JSON points at one:
#    DB_IMAGE      ghcr.io/…/cloud-cgc-mcp-octocode-db:latest   (.db_publish.image:tag)
#    DB_VOLUME     octocode_db                                  (.runtime.octocode.db_volume)
#    MCP_CONTAINER cloud-cgc-mcp                                (.containers.app.container_name)
#    NTFY_URL      http://10.0.0.6:8090                         (optional)
# ──────────────────────────────────────────────────────────────────────────
set -eu
jbj() { [ -n "${CGC_BUILD_JSON:-}" ] && [ -f "$CGC_BUILD_JSON" ] && jq -r "$1" "$CGC_BUILD_JSON" 2>/dev/null || echo ""; }
IMAGE="${DB_IMAGE:-$(jbj '.db_publish.image + ":" + (.db_publish.tag // "latest")')}"
VOLUME="${DB_VOLUME:-$(jbj '.runtime.octocode.db_volume')}"
CONTAINER="${MCP_CONTAINER:-$(jbj '.containers.app.container_name')}"
NTFY="${NTFY_URL:-}"
[ -n "$IMAGE" ] && [ -n "$VOLUME" ] || { echo "::error::need DB_IMAGE + DB_VOLUME (env or build.json)"; exit 1; }

echo "[cgc-db] restore $IMAGE → volume $VOLUME"
docker pull "$IMAGE"
# busybox image carries the DB at /octocode-db; cp -a preserves the Lance/FastEmbed layout.
docker run --rm -v "${VOLUME}:/dst" "$IMAGE" sh -c 'cp -a /octocode-db/. /dst/'
echo "[cgc-db] restored into volume $VOLUME"

if [ -n "$CONTAINER" ]; then
  docker restart "$CONTAINER" >/dev/null 2>&1 && echo "[cgc-db] restarted $CONTAINER" \
    || echo "[cgc-db] WARN restart $CONTAINER failed"
fi
if [ -n "$NTFY" ]; then
  curl -sf -d "cloud-cgc octocode DB restored from GHCR + $CONTAINER restarted" \
    -H "Title: cgc-db restore" -H "Tags: arrow_down,white_check_mark" "$NTFY/ops" >/dev/null 2>&1 || true
fi
echo "[cgc-db] RESTORE COMPLETE"
