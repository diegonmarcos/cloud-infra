#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_workflows/src/scripts/cloud-cgc-kg-ingest.sh
# ║   Engine : 1_workflows/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ──────────────────────────────────────────────────────────────────────────
#  cloud-cgc-kg-ingest.sh — mirror octocode's code graph → kg-store (SurrealDB)
# ──────────────────────────────────────────────────────────────────────────
#  The kg-store (SurrealDB `file` / `sibling_module` tables — what the cgc.kgstore.*
#  tools query) is ONLY fed by the one-shot reindex.sh. The daily pipeline
#  (GHA producer → oci-apps Dagu consumer) refreshes the octocode Lance DB but
#  NEVER the kg-store → the kg-store drifts from the codegraph (e.g. front's
#  status.ts → status/ refactor shows in the codegraph but not the kg-store).
#
#  THIS script closes that gap: it mirrors the CURRENT octocode Lance DB (already
#  restored into the octocode_db volume by cloud-cgc-db-restore.sh) into the
#  kg-store, per repo, then ingests the infra graph delta. Runs ON oci-apps
#  (where the cloud-cgc-mcp container + SurrealDB live) via `docker exec`.
#
#  Two GHA workflows trigger it (ZERO logic in either YAML — all here):
#    (a) ship-cgc-kg-store.yml      — runs on the oci-apps self-hosted runner,
#                                     executes this script directly from checkout.
#    (b) ship-cgc-kg-store-ssh.yml  — runs on ubuntu-latest, WireGuard up, SSHes
#                                     into oci-apps and streams this script (sh -s).
#
#  Both are workflow_dispatch (manual / on-demand). Data-driven from build.json
#  (present on the self-hosted runner's checkout) with env-var fallback (so the
#  SSH-streamed path (b) works without a checkout on oci-apps — the GHA runner
#  reads build.json and passes CONTAINER + REPOS via env, mirroring the Dagu DAG
#  pattern in ops_octocode-db-pull.yaml).
#
#  Logic per repo (identical to reindex.sh lines 95-112):
#    docker exec <ctr> python3 /app/octocode-export.py <repo>
#      → reads Lance tables in octocode_db volume → /app/graphs/octocode-<repo>.json
#    docker exec <ctr> sh -c 'KG_DELTA=/app/graphs/octocode-<repo>.json node /app/kg-ingest.mjs'
#      → UPSERT nodes + RELATE edges into SurrealDB (KG_STORE_PASS from container env)
#  Final: docker exec <ctr> node /app/kg-ingest.mjs   (infra graph delta, default KG_DELTA)
#
#  Runtime needs on oci-apps: docker + the cloud-cgc-mcp container running.
# ──────────────────────────────────────────────────────────────────────────
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${CLOUD_ROOT:-$(cd "$HERE/../../.." && pwd)}"
BJ="${CGC_BUILD_JSON:-$ROOT/a_solutions/user-ai_cloud-cgc-mcp/build.json}"

# build.json fallback (env-var first, same pattern as cloud-cgc-db-restore.sh).
jbj() { [ -n "${CGC_BUILD_JSON:-}" ] && [ -f "$BJ" ] && jq -r "$1" "$BJ" 2>/dev/null || echo ""; }

CTR="${MCP_CONTAINER:-$(jbj '.containers.app.container_name')}"
[ -n "$CTR" ] || { echo "::error::need MCP_CONTAINER (env) or containers.app.container_name (build.json)"; exit 1; }

if [ -n "${OCTOCODE_REPOS:-}" ]; then
  REPOS="$OCTOCODE_REPOS"
else
  REPOS="$(jbj '.runtime.octocode.index_repos | join(" ")')"
fi
[ -n "$REPOS" ] || { echo "::error::need OCTOCODE_REPOS (env) or runtime.octocode.index_repos (build.json)"; exit 1; }

NTFY="${NTFY_URL:-}"

echo "[kg-ingest] container=$CTR repos=[$REPOS]"
echo "[kg-ingest] (KG_STORE_URL/NS/DB/USER/PASS + KG_GRAPHS_DIR come from the container env — docker exec inherits them)"

command -v docker >/dev/null 2>&1 || { echo "::error::docker not found — this script must run on oci-apps"; exit 1; }

# Verify the container is up (docker exec fails on a stopped container). Start it
# if stopped (a cold MCP after a redeploy); fail loud if it doesn't exist at all.
if ! docker inspect -f '{{.State.Running}}' "$CTR" 2>/dev/null | grep -q true; then
  if docker inspect "$CTR" >/dev/null 2>&1; then
    echo "[kg-ingest] $CTR is stopped — starting it"
    docker start "$CTR" >/dev/null 2>&1 || { echo "::error::failed to start $CTR"; exit 1; }
    sleep 3
  else
    echo "::error::container $CTR does not exist — deploy cloud-cgc-mcp first"; exit 1
  fi
fi

ok=0; fail=0
for repo in $REPOS; do
  echo "[kg-ingest] === $repo · export octocode Lance → delta JSON ==="
  if docker exec "$CTR" python3 /app/octocode-export.py "$repo" 2>&1; then
    echo "[kg-ingest] === $repo · ingest delta → SurrealDB ==="
    if docker exec "$CTR" sh -c "KG_DELTA=/app/graphs/octocode-$repo.json node /app/kg-ingest.mjs" 2>&1; then
      echo "[kg-ingest] $repo ✓ ingested"
      ok=$((ok+1))
    else
      echo "[kg-ingest] $repo ✗ kg-ingest.mjs failed (continuing)"
      fail=$((fail+1))
    fi
  else
    echo "[kg-ingest] $repo ✗ octocode-export.py failed — skipping ingest (continuing)"
    fail=$((fail+1))
  fi
done

echo "[kg-ingest] === infra graph delta → SurrealDB (default KG_DELTA) ==="
if docker exec "$CTR" node /app/kg-ingest.mjs 2>&1; then
  echo "[kg-ingest] infra graph ✓ ingested"
else
  echo "[kg-ingest] infra graph ingest failed (continuing — env-gated, may no-op if KG_STORE_PASS unset)"
fi

echo "[kg-ingest] DONE — repos ok=$ok fail=$fail"
if [ -n "$NTFY" ]; then
  curl -sf -d "cloud-cgc kg-store ingest: ok=$ok fail=$fail (repos: $REPOS)" \
    -H "Title: cgc-kg-store" -H "Tags: database,white_check_mark" "$NTFY/ops" >/dev/null 2>&1 || true
fi
[ "$fail" = "0" ] || exit 0   # non-fatal: partial ingest still advances the kg-store
