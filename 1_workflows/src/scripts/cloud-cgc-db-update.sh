#!/bin/sh
# ──────────────────────────────────────────────────────────────────────────
#  cloud-cgc-db-update.sh — UNIVERSAL cloud-cgc octocode DB updater (producer)
# ──────────────────────────────────────────────────────────────────────────
#  ONE reproducible script that runs IDENTICALLY anywhere (GHA x86, a VM, local).
#  The CI YAML / Dagu DAG only TRIGGER this — they carry ZERO logic. Everything
#  (octocode install, GHCR auth, fresh repo checkout, index, package, push) is
#  here and data-driven from build.json.
#
#  GHCR-upstream INCREMENTAL flow (NOT a reindex — never `octocode clear`):
#    0. ensure octocode on PATH (extract pinned x86 static binary from GHCR)
#    1. ensure GHCR auth (docker login if a token is provided)
#    2. ensure repos: clone/refresh each to its FRESH origin HEAD in a DEDICATED
#       root (never the dev tree) — this is what guarantees "freshest HEAD"
#    3. pull the last DB from GHCR (incremental base; bootstraps if absent)
#    4. octocode index each repo — git-aware, CHANGED FILES ONLY
#       GraphRAG LLM phase → OpenRouter ($OPENROUTER_API_KEY); FastEmbed local
#    5. push the updated DB back to GHCR (single upstream for all consumers)
#  The DB (Lance + FastEmbed vectors) is arch-portable; octocode version is
#  pinned in build.json so the schema stays compatible across x86/arm/local.
#
#  INCREMENTAL-ONLY: requires an existing GHCR DB base (seed it once via
#  cloud-cgc-db-package.sh of an already-built DB, or a prod-volume snapshot).
#  It refuses a from-scratch full build (octocode's GraphRAG full build is ~12h).
#  Runtime the caller (YAML/DAG/shell) must provide: docker, git, jq + env:
#    GITHUB_TOKEN (+ GITHUB_ACTOR) for GHCR/clone auth, OPENROUTER_API_KEY (opt).
# ──────────────────────────────────────────────────────────────────────────
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${CLOUD_ROOT:-$(cd "$HERE/../../.." && pwd)}"
BJ="${CGC_BUILD_JSON:-$ROOT/a_solutions/user-ai_cloud-cgc-mcp/build.json}"
[ -f "$BJ" ] || { echo "::error::cloud-cgc-mcp build.json not found at $BJ"; exit 1; }

IMAGE=$(jq -r   '.db_publish.image'                  "$BJ")
TAG=$(jq -r     '.db_publish.tag // "latest"'        "$BJ")
OCTO_HOME="${OCTOCODE_HOME:-$HOME/.local/share/octocode}"
# FIXED clone root, identical everywhere. octocode keys each project by its
# git-root path STRING, so to do incremental ON TOP of the existing GHCR/prod
# DB (which was built in the octocode container at /repos), the producer MUST
# clone+index at the SAME path. Anything $HOME-relative (varies per machine →
# /home/diego vs /home/runner) creates a DISCONNECTED graph — the bug that made
# the 357-node orphan instead of extending the 2148-node base. Data-driven from
# build.json runtime.octocode.repos_path; NEVER the dev tree (~/git).
REPOS_ROOT="${REPOS_ROOT:-${OCTOCODE_REPOS_ROOT:-$(jq -r '.runtime.octocode.repos_path // "/repos"' "$BJ")}}"
# CGC_INDEX_REPOS overrides build.json for split-job workflows (space-separated)
if [ -n "${CGC_INDEX_REPOS:-}" ]; then
  REPOS="$CGC_INDEX_REPOS"
else
  REPOS=$(jq -r '.runtime.octocode.index_repos[]' "$BJ")
fi
LLM=$(jq -r     '.runtime.octocode.update.llm_model' "$BJ")
USE_LLM=$(jq -r '.runtime.octocode.update.use_llm'   "$BJ")
OCTO_X86=$(jq -r '.runtime.octocode.octocode_images.x86' "$BJ")
CFG="$OCTO_HOME/config.toml"
TOKEN="${GHCR_TOKEN:-${GITHUB_TOKEN:-}}"
ACTOR="${GITHUB_ACTOR:-diegonmarcos}"
export HOME OCTOCODE_HOME="$OCTO_HOME"

# 0) ensure octocode on PATH — extract the pinned x86 static binary from its GHCR
#    image (data-driven). No-op when octocode is already installed (e.g. local).
ensure_octocode() {
  command -v octocode >/dev/null 2>&1 && { echo "[cgc-db] octocode: $(octocode --version 2>/dev/null)"; return 0; }
  command -v docker >/dev/null 2>&1 || { echo "::error::need octocode or docker to obtain it"; exit 1; }
  bindir="${CGC_BIN:-$HOME/.local/bin}"; mkdir -p "$bindir"
  echo "[cgc-db] installing pinned octocode from $OCTO_X86"
  docker pull -q "$OCTO_X86" >/dev/null
  docker run --rm --entrypoint sh "$OCTO_X86" -c 'cat "$(command -v octocode)"' > "$bindir/octocode"
  chmod +x "$bindir/octocode"
  PATH="$bindir:$PATH"; export PATH
  octocode --version
}

# 1) ensure GHCR auth — only if a token is provided (local is usually pre-authed).
ensure_ghcr_auth() {
  [ -n "$TOKEN" ] || { echo "[cgc-db] no token — assuming GHCR already authed"; return 0; }
  echo "$TOKEN" | docker login ghcr.io -u "$ACTOR" --password-stdin >/dev/null 2>&1 \
    && echo "[cgc-db] GHCR login ok" || echo "[cgc-db] WARN GHCR login failed"
}

# 2) ensure each indexed repo is present at its FRESH origin HEAD in REPOS_ROOT.
#    Data-driven local→github from build.json.repo_map. clone if missing, else
#    fetch + reset --hard to the fetched tip. Safe (dedicated clones, not dev tree).
ensure_repos() {
  # /repos is root-owned on a fresh runner — create + own it (sudo) if needed.
  mkdir -p "$REPOS_ROOT" 2>/dev/null || { sudo mkdir -p "$REPOS_ROOT" && sudo chown "$(id -un):$(id -gn)" "$REPOS_ROOT"; }
  jq -r '.runtime.octocode.repo_map | to_entries[] | "\(.key) \(.value)"' "$BJ" | while read -r lname remote; do
    [ -n "$lname" ] || continue
    d="$REPOS_ROOT/$lname"
    if [ -n "$TOKEN" ]; then url="https://x-access-token:${TOKEN}@github.com/diegonmarcos/${remote}.git"
    else url="https://github.com/diegonmarcos/${remote}.git"; fi
    if [ -d "$d/.git" ]; then
      echo "[cgc-db] refresh $lname ← origin (full history for incremental detection)"
      git -C "$d" remote set-url origin "$url" 2>/dev/null || true
      git -C "$d" fetch -q origin 2>/dev/null \
        && git -C "$d" reset --hard -q FETCH_HEAD 2>/dev/null \
        || echo "[cgc-db] WARN refresh $lname failed (using existing checkout)"
    else
      echo "[cgc-db] clone $lname ← $remote (full history for incremental detection)"
      # Full clone (no --depth): octocode stores the last-indexed commit in the DB and
      # diffs against it to find changed files. --depth 1 puts that stored commit outside
      # the shallow history → git can't resolve it → octocode re-indexes everything every
      # run. Full clone is small overhead; the embedding speedup is enormous (minutes vs hours).
      git clone -q "$url" "$d" 2>/dev/null || echo "[cgc-db] WARN clone $lname failed"
    fi
  done
}

# octocode (ignore crate) DEADLOCKS recursing nested submodules — each submodule
# is its own repo (indexed separately). Exclude them via .git/info/exclude
# (LOCAL + untracked → never touches tracked .gitignore). Data-driven from the
# repo's own .gitmodules. Idempotent.
exclude_submodules() {
  _d="$1"; _gm="$_d/.gitmodules"; _ex="$_d/.git/info/exclude"
  [ -f "$_gm" ] && [ -d "$_d/.git" ] || return 0
  mkdir -p "$_d/.git/info"
  awk -F'=' '/^[[:space:]]*path[[:space:]]*=/ { gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2 }' "$_gm" | while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    grep -qxF "/$_p/" "$_ex" 2>/dev/null || printf '/%s/\n' "$_p" >> "$_ex"
    echo "[cgc-db] $_d · exclude submodule from octocode walk: $_p"
  done
}

# Propagate the freshly-pushed DB to the DEPLOYED consumer: SSH to the deploy
# host and run cloud-cgc-db-restore.sh there (pull GHCR DB → restore the
# octocode_db volume → restart the MCP container). This is what GUARANTEES the
# deployed oci-apps server actually serves the new DB after every update — the
# restore logic is streamed (sh -s), so nothing has to be pre-deployed. Data-
# driven (host/volume/container from build.json). Non-fatal if unreachable
# (e.g. mesh down). Caller provides WG + an SSH alias for db_publish.host.
propagate_to_host() {
  _host=$(jq -r '.db_publish.host // empty' "$BJ")
  [ -n "$_host" ] && [ "$_host" != "local" ] || { echo "[cgc-db] no deploy host — skip propagate"; return 0; }
  command -v ssh >/dev/null 2>&1 || { echo "[cgc-db] no ssh — skip propagate"; return 0; }
  _vol=$(jq -r '.runtime.octocode.db_volume'   "$BJ")
  _ctr=$(jq -r '.containers.app.container_name' "$BJ")
  # Resolve the SSH target data-driven: in CI, build-gha.json maps the alias →
  # user@wg_ip (no ~/.ssh/config needed); locally, fall back to the ssh alias.
  _gha="$ROOT/2_configs/dist/build-gha.json"
  _target="$_host"
  if [ -f "$_gha" ]; then
    _wgip=$(jq -r --arg h "$_host" '.vms[$h].wg_ip // empty'  "$_gha" 2>/dev/null)
    _user=$(jq -r --arg h "$_host" '.vms[$h].user // "ubuntu"' "$_gha" 2>/dev/null)
    [ -n "$_wgip" ] && _target="$_user@$_wgip"
  fi
  echo "[cgc-db] propagate → $_target (pull $IMAGE:$TAG + restart $_ctr)"
  # shellcheck disable=SC2086
  ssh ${CGC_SSH_OPTS:-} "$_target" \
      "DB_IMAGE='$IMAGE:$TAG' DB_VOLUME='$_vol' MCP_CONTAINER='$_ctr' NTFY_URL='${NTFY_URL:-}' sh -s" \
      < "$HERE/cloud-cgc-db-restore.sh" \
    && echo "[cgc-db] propagate OK — $_host now serving the new DB" \
    || echo "[cgc-db] WARN propagate to $_host failed (host unreachable / mesh down)"
}

# ── run ───────────────────────────────────────────────────────────────────
ensure_octocode
ensure_ghcr_auth
ensure_repos

# 3) restore the incremental base from GHCR. The producer is INCREMENTAL-ONLY —
# it must NEVER full-build from scratch (octocode's GraphRAG full build is ~12h,
# O(N²) relationships). The base is created ONCE by a seed: cloud-cgc-db-package.sh
# of an already-built octocode DB, or a prod-volume snapshot. Refuse without a base.
mkdir -p "$OCTO_HOME"
sh "$HERE/cloud-cgc-db-pull.sh" "$OCTO_HOME" || true
if [ -z "$(ls -A "$OCTO_HOME" 2>/dev/null | grep -v '^config\.toml$')" ]; then
  echo "::error::no GHCR DB base restored — refusing a from-scratch full build (~12h)."
  echo "::error::seed once first: sh $HERE/cloud-cgc-db-package.sh <existing-octocode-home> $IMAGE $TAG"
  exit 1
fi
[ -f "$CFG" ] || octocode config >/dev/null 2>&1 || true

# 4a) force the GraphRAG LLM phase on (use_llm + model). awk, never sed.
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

# 4b) INCREMENTAL index per repo — git-aware, changed files only. NO `octocode clear`.
command -v git >/dev/null 2>&1 && git config --global --add safe.directory '*' >/dev/null 2>&1 || true
for r in $REPOS; do
  d="$REPOS_ROOT/$r"
  [ -d "$d" ] || { echo "[cgc-db] MISSING $d — skip"; continue; }
  exclude_submodules "$d"
  echo "[cgc-db] === incremental index: $r ==="
  ( cd "$d" && octocode index ) 2>&1 | tail -4 || echo "[cgc-db] index $r FAILED (continuing)"
done

# 5) publish the updated DB back to GHCR (single upstream for all consumers)
sh "$HERE/cloud-cgc-db-package.sh" "$OCTO_HOME" "$IMAGE" "$TAG"

# 6) GUARANTEE the deployed consumer (oci-apps) pulls the new DB + restarts,
#    so the live server serves it immediately — not only on the next DAG tick.
#    CGC_SKIP_PROPAGATE=1 lets split-job workflows defer propagation to the last job.
if [ "${CGC_SKIP_PROPAGATE:-}" = "1" ]; then
  echo "[cgc-db] propagation deferred (CGC_SKIP_PROPAGATE=1)"
else
  propagate_to_host
fi

echo "[cgc-db] UPDATE COMPLETE → $IMAGE:$TAG"
