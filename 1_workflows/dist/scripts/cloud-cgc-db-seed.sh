#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_workflows/src/scripts/cloud-cgc-db-seed.sh
# ║   Engine : 1_workflows/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ──────────────────────────────────────────────────────────────────────────
#  cloud-cgc-db-seed.sh — SEED GHCR from the EXISTING complete octocode DB
# ──────────────────────────────────────────────────────────────────────────
#  Snapshots the already-built octocode DB on the deploy host (oci-apps
#  `octocode_db` volume — the comprehensive ~12h GraphRAG full build, ~2148
#  nodes) → GHCR `cloud-cgc-mcp-octocode-db:latest`. This is the BOOTSTRAP base
#  the incremental producer builds on. NEVER rebuild from scratch — preserve
#  this. Run once (or to re-base) from anywhere that can SSH the host (GHA WG).
#
#  Data-driven from build.json: db_publish.{image,tag,host,volume}. SSH target
#  resolved from build-gha.json (user@wg_ip) in CI, ssh alias locally. Reuses
#  cloud-cgc-db-package.sh for the GHCR build/push (DRY).
# ──────────────────────────────────────────────────────────────────────────
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${CLOUD_ROOT:-$(cd "$HERE/../../.." && pwd)}"
BJ="${CGC_BUILD_JSON:-$ROOT/a_solutions/user-ai_cloud-cgc-mcp/build.json}"
[ -f "$BJ" ] || { echo "::error::cloud-cgc-mcp build.json not found at $BJ"; exit 1; }

IMAGE=$(jq -r '.db_publish.image'                       "$BJ")
TAG=$(jq -r   '.db_publish.tag // "latest"'             "$BJ")
HOST=$(jq -r  '.db_publish.host'                        "$BJ")
VOLUME=$(jq -r '.db_publish.volume // .runtime.octocode.db_volume' "$BJ")
[ -n "$IMAGE" ] && [ -n "$HOST" ] && [ -n "$VOLUME" ] || { echo "::error::need db_publish.{image,host,volume}"; exit 1; }

# Resolve the SSH target data-driven (CI: user@wg_ip from build-gha.json; local: ssh alias).
GHA="$ROOT/2_configs/dist/build-gha.json"
TARGET="$HOST"
if [ -f "$GHA" ]; then
  WGIP=$(jq -r --arg h "$HOST" '.vms[$h].wg_ip // empty'  "$GHA" 2>/dev/null)
  SUSER=$(jq -r --arg h "$HOST" '.vms[$h].user // "ubuntu"' "$GHA" 2>/dev/null)
  [ -n "$WGIP" ] && TARGET="$SUSER@$WGIP"
fi

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/db"
echo "[cgc-db] seed: streaming volume '$VOLUME' from $TARGET ..."
# busybox is always pullable; volume mounted :ro so the live MCP is undisturbed.
# shellcheck disable=SC2086
ssh ${CGC_SSH_OPTS:-} "$TARGET" \
  "docker run --rm -v ${VOLUME}:/db:ro busybox tar cf - -C /db ." \
  | tar xf - -C "$WORK/db"
[ -n "$(ls -A "$WORK/db" 2>/dev/null)" ] || { echo "::error::empty DB streamed from $TARGET:$VOLUME"; exit 1; }
echo "[cgc-db] seed: received $(du -sh "$WORK/db" | cut -f1) ($(ls -d "$WORK/db"/*/ 2>/dev/null | wc -l) projects)"

# Build + push to GHCR via the shared packaging path.
sh "$HERE/cloud-cgc-db-package.sh" "$WORK/db" "$IMAGE" "$TAG"
echo "[cgc-db] SEED COMPLETE → $IMAGE:$TAG (from existing $HOST:$VOLUME)"
