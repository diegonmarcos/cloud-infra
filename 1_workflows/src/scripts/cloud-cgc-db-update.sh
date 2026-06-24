#!/bin/sh
# ──────────────────────────────────────────────────────────────────────────
#  cloud-cgc-db-update.sh — INCREMENTAL cloud-cgc octocode DB update (producer)
# ──────────────────────────────────────────────────────────────────────────
#  GHCR-upstream incremental flow (NOT a reindex — never `octocode clear`):
#    1. pull the last DB from GHCR        (cloud-cgc-db-pull.sh)
#    2. octocode index each repo           (git-aware, CHANGED FILES ONLY)
#       GraphRAG LLM phase → OpenRouter ($OPENROUTER_API_KEY); FastEmbed local.
#    3. push the updated DB back to GHCR   (cloud-cgc-db-package.sh)
#  Runs on x86 (GHA) — the DB (Lance + FastEmbed vectors) is arch-portable, so
#  oci-apps (arm) + local just consume it. octocode version is pinned in
#  build.json so the on-disk schema stays compatible across x86/arm/local.
#  Thin-wrapper: ALL logic here; the GHA workflow only provides runtime
#  (x86 octocode on PATH, GHCR login, $OPENROUTER_API_KEY, the repos checked out).
#  First run with no upstream image bootstraps a full build once to seed GHCR.
# ──────────────────────────────────────────────────────────────────────────
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${CLOUD_ROOT:-$(cd "$HERE/../../.." && pwd)}"
BJ="${CGC_BUILD_JSON:-$ROOT/a_solutions/user-ai_cloud-cgc-mcp/build.json}"
[ -f "$BJ" ] || { echo "::error::cloud-cgc-mcp build.json not found at $BJ"; exit 1; }

IMAGE=$(jq -r '.db_publish.image'                 "$BJ")
TAG=$(jq -r   '.db_publish.tag // "latest"'       "$BJ")
OCTO_HOME="${OCTOCODE_HOME:-$HOME/.local/share/octocode}"
REPOS=$(jq -r '.runtime.octocode.index_repos[]'   "$BJ")
REPOS_ROOT="${REPOS_ROOT:-${OCTOCODE_REPOS_ROOT:-$HOME/git}}"
LLM=$(jq -r     '.runtime.octocode.update.llm_model' "$BJ")
USE_LLM=$(jq -r '.runtime.octocode.update.use_llm'   "$BJ")
CFG="$OCTO_HOME/config.toml"
export HOME OCTOCODE_HOME="$OCTO_HOME"

# 1) seed the incremental base from GHCR (no-op if not seeded yet → full build)
mkdir -p "$OCTO_HOME"
sh "$HERE/cloud-cgc-db-pull.sh" "$OCTO_HOME" || echo "[cgc-db] pull skipped — bootstrapping a fresh DB"
[ -f "$CFG" ] || octocode config >/dev/null 2>&1 || true

# 2) force the GraphRAG LLM phase on (use_llm + model). awk, never sed (model is plain).
if [ "$USE_LLM" = "true" ] && [ -n "${OPENROUTER_API_KEY:-}" ] && [ -f "$CFG" ]; then
  octocode config --model "$LLM" --graphrag-enabled true >/dev/null 2>&1 || true
  awk -v m="$LLM" '
    /^[[:space:]]*use_llm[[:space:]]*=/            { print "use_llm = true"; next }
    /^[[:space:]]*description_model[[:space:]]*=/  { print "description_model = \"" m "\""; next }
    /^[[:space:]]*relationship_model[[:space:]]*=/ { print "relationship_model = \"" m "\""; next }
    { print }' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
  grep -q "use_llm = true" "$CFG" 2>/dev/null || printf '\n[graphrag]\nuse_llm = true\n' >> "$CFG"
  echo "[cgc-db] GraphRAG LLM = $LLM (use_llm=true)"
else
  echo "[cgc-db] GraphRAG structural-only (use_llm disabled or no OPENROUTER_API_KEY)"
fi

# 3) INCREMENTAL index per repo — git-aware, changed files only. NO `octocode clear`.
command -v git >/dev/null 2>&1 && git config --global --add safe.directory '*' >/dev/null 2>&1 || true
for r in $REPOS; do
  d="$REPOS_ROOT/$r"
  [ -d "$d" ] || { echo "[cgc-db] MISSING $d — skip"; continue; }
  echo "[cgc-db] === incremental index: $r ==="
  ( cd "$d" && octocode index ) 2>&1 | tail -4 || echo "[cgc-db] index $r FAILED (continuing)"
done

# 4) publish the updated DB back to GHCR (single upstream for all consumers)
sh "$HERE/cloud-cgc-db-package.sh" "$OCTO_HOME" "$IMAGE" "$TAG"
echo "[cgc-db] UPDATE COMPLETE → $IMAGE:$TAG"
