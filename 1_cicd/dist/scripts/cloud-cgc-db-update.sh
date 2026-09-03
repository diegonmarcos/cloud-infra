#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_cicd/src/ops/cloud-cgc-db-update.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

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
#       GraphRAG LLM phase → my-ai-api (.runtime.octocode.llm); FastEmbed local
#    5. push the updated DB back to GHCR (single upstream for all consumers)
#  The DB (Lance + FastEmbed vectors) is arch-portable; octocode version is
#  pinned in build.json so the schema stays compatible across x86/arm/local.
#
#  INCREMENTAL-ONLY: requires an existing GHCR DB base (seed it once via
#  cloud-cgc-db-package.sh of an already-built DB, or a prod-volume snapshot).
#  It refuses a from-scratch full build (octocode's GraphRAG full build is ~12h).
#  Runtime the caller (YAML/DAG/shell) must provide: docker, git, jq + env:
#    GITHUB_TOKEN (+ GITHUB_ACTOR) for GHCR/clone auth. No LLM key: the endpoint
#    declared in .runtime.octocode.llm injects its own, so callers send a
#    placeholder and nothing here ever holds a provider credential.
# ──────────────────────────────────────────────────────────────────────────
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${CLOUD_ROOT:-$(cd "$HERE/../../.." && pwd)}"
BJ="${CGC_BUILD_JSON:-$ROOT/a_solutions/user-ai_cloud-cgc-pub-mcp/build.json}"
[ -f "$BJ" ] || { echo "::error::cloud-cgc-pub-mcp build.json not found at $BJ"; exit 1; }

IMAGE=$(jq -r   '.db_publish.image'                  "$BJ")
TAG=$(jq -r     '.db_publish.tag // "latest"'        "$BJ")
OCTO_HOME="${OCTOCODE_HOME:-$HOME/.local/share/octocode}"
# ── XDG alignment (per-repo/matrix mode only) — production incident 2026-08-21
# (run 32512759559): octocode 0.12.2 has NO relocation knob of its own
# (verified against the pinned binary's storage.rs:39-47) — it derives its OWN
# data dir from $XDG_DATA_HOME (preferred) else $HOME/.local/share, full stop.
# OCTOCODE_HOME/OCTO_HOME above is OUR variable only; octocode never reads it.
# Every octocode invocation below (ensure_octocode, `octocode config`,
# `octocode index`) resolves its home from XDG_DATA_HOME/HOME alone, no matter
# what OCTO_HOME points at — so the two must be made to agree BEFORE the first
# such invocation, or octocode silently indexes into one directory while this
# script packages another.
#   monolith mode (default, untouched below): OCTO_HOME defaults to
#     $HOME/.local/share/octocode — the SAME path octocode itself resolves
#     with XDG_DATA_HOME unset. The two can never disagree, which is WHY this
#     path has always worked with no XDG handling at all.
#   per-repo mode (matrix CI, cgc-db-index.yml): OCTOCODE_HOME is set to a
#     FRESH per-job dir under $RUNNER_TEMP (e.g. $RUNNER_TEMP/octocode-home),
#     never $HOME/.local/share/octocode — so without the export below,
#     `octocode index` silently writes the real DB to
#     $HOME/.local/share/octocode instead (that run: octocode indexed fine,
#     every job then failed "no project directory found" packaging the
#     empty, un-written OCTO_HOME). Fix: require/normalize OCTO_HOME to END
#     in "/octocode" and export XDG_DATA_HOME as its PARENT, so octocode's
#     own $XDG_DATA_HOME/octocode resolution lands exactly on $OCTO_HOME —
#     the same directory bootstrap_config_toml (below) already writes
#     config.toml into, now kept in alignment for the DB itself too.
if [ "${CGC_PACKAGE_MODE:-monolith}" = "per-repo" ]; then
  case "$OCTO_HOME" in
    */octocode) ;;
    *)
      echo "::warning::[cgc-db] CGC_PACKAGE_MODE=per-repo: OCTOCODE_HOME ($OCTO_HOME) does not end in /octocode — normalizing to $OCTO_HOME/octocode so octocode's own XDG_DATA_HOME resolution lands on it"
      OCTO_HOME="$OCTO_HOME/octocode"
      ;;
  esac
  mkdir -p "$OCTO_HOME"
  XDG_DATA_HOME="${OCTO_HOME%/octocode}"
  export XDG_DATA_HOME
fi
# Embedding-model cache. Since 0.22 octocode keeps its fastembed models under
# $XDG_CACHE_HOME/octolib/fastembed, no longer inside the octocode home. Point the
# cache INSIDE the home, at fastembed/, so the base image keeps carrying the model
# cache exactly as before (cloud-cgc-db-package.sh's root-state allowlist and
# cloud-cgc-db-restore-all.sh's project-dir exclusion both already name that
# directory) and the consumers find the models restored instead of downloading
# them at first query. compose.nix sets the same variable on the consumer side.
XDG_CACHE_HOME="$OCTO_HOME/fastembed"; export XDG_CACHE_HOME
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
# DENY CHECK — derive-repo-map.ts only validates the STATIC build.json index_repos
# at derive time; CGC_INDEX_REPOS above lets a caller (a local run with real deploy/SSH
# keys, say) override REPOS at runtime and skip that check entirely. The shared /repos
# volume is what cloud-cgc-pub-mcp indexes, so a denied repo (e.g. cloud-vault, the
# credential store) reaching this loop gets embedded in the GraphRAG DB and
# checkpoint-pushed to GHCR — i.e. published. Re-check the FINAL $REPOS (whichever path
# set it) against the SAME deny list, data-driven from build.json — never hardcode a name.
DENY=$(jq -r '(.runtime.octocode.sync_exclude // {}) | keys[]?' "$BJ")
for _r in $REPOS; do
  for _d in $DENY; do
    if [ "$_r" = "$_d" ]; then
      _reason=$(jq -r --arg r "$_r" '.runtime.octocode.sync_exclude[$r] // "denied"' "$BJ")
      echo "::error::[cgc-db] refusing to index '$_r' — denied by .runtime.octocode.sync_exclude ($_reason)"
      exit 1
    fi
  done
done
# Same deny list, ALSO checked against .runtime.octocode.repo_map — a separate list
# (local_name → github remote) that ensure_repos() below clones from independently of
# $REPOS/index_repos. A denied name added to repo_map (by hand, bypassing derive-repo-
# map.ts) would otherwise clone straight to the shared REPOS_ROOT unchecked — this loop
# above only ever sees $REPOS, never repo_map's keys. Inert today (repo_map has no
# sync_exclude entry), but the whole point of a deny list is to hold even when someone
# adds one by hand later.
for _r in $(jq -r '(.runtime.octocode.repo_map // {}) | keys[]?' "$BJ"); do
  for _d in $DENY; do
    if [ "$_r" = "$_d" ]; then
      _reason=$(jq -r --arg r "$_r" '.runtime.octocode.sync_exclude[$r] // "denied"' "$BJ")
      echo "::error::[cgc-db] refusing to clone '$_r' — denied by .runtime.octocode.sync_exclude ($_reason), present in .runtime.octocode.repo_map"
      exit 1
    fi
  done
done
LLM=$(jq -r     '.runtime.octocode.update.llm_model' "$BJ")
# USE_LLM selects the GraphRAG LLM phase. Two-phase orchestration (cgc-db.yml →
# cgc-db-index.yml) drives this via the environment: the `semantic` phase exports
# USE_LLM=false, the `graphrag` phase exports USE_LLM=true. The ENVIRONMENT is
# authoritative; build.json runtime.octocode.update.use_llm is only the fallback
# default when the caller does not set USE_LLM (e.g. a bare local invocation).
USE_LLM="${USE_LLM:-$(jq -r '.runtime.octocode.update.use_llm' "$BJ")}"
# GraphRAG LLM ENDPOINT (data-driven, .runtime.octocode.llm). octocode picks its
# provider from the model-string PREFIX and then reads that provider's OWN env
# pair: `openrouter:*` -> $OPENROUTER_API_URL + $OPENROUTER_API_KEY, `openai:*`
# -> $OPENAI_API_URL + $OPENAI_API_KEY, `ollama:*` -> $OLLAMA_API_URL. All three
# are exported so the declared prefix is the only thing that has to change to
# switch faces. openrouter: is the one in use: the openai provider validates the
# model against a slug allowlist and rejects `qwen/*` outright, and ollama: is
# the mimic port rather than the API this account actually pays for. Nothing
# else sets any of these, so
# without this block the graphrag phase rewrote the config models correctly and
# then died at the first call with "LLM client not initialized" -> a whole DB of
# structural-only `sibling_module` edges with only a Warning in the log.
# The endpoint is my-ai-api on the mesh, which injects the real OpenRouter key
# itself (passthrough_auth=false), so api_key here is the declared `sk-dummy`
# placeholder — there is NO credential in this path and none is needed.
# ENVIRONMENT WINS, build.json is the default — the same precedence USE_LLM uses.
# A caller that reaches the endpoint by another route (an SSH forward from a
# runner that cannot route to the mesh IP) sets these and is obeyed.
OPENROUTER_API_URL="${OPENROUTER_API_URL:-$(jq -r '.runtime.octocode.llm.openrouter_api_url // empty' "$BJ")}"
OPENAI_API_URL="${OPENAI_API_URL:-$(jq -r '.runtime.octocode.llm.openai_api_url     // empty' "$BJ")}"
OLLAMA_API_URL="${OLLAMA_API_URL:-$(jq -r '.runtime.octocode.llm.ollama_api_url     // empty' "$BJ")}"
OPENAI_API_KEY="${OPENAI_API_KEY:-$(jq -r '.runtime.octocode.llm.api_key            // empty' "$BJ")}"
LLM_HEALTH_URL="${LLM_HEALTH_URL:-$(jq -r '.runtime.octocode.llm.health_url         // empty' "$BJ")}"
# One declared placeholder feeds every provider's key var: my-ai-api ignores what
# the caller sends, but octocode refuses to build a client when the var is empty.
OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-$OPENAI_API_KEY}"
export OPENROUTER_API_URL OPENAI_API_URL OLLAMA_API_URL OPENAI_API_KEY OPENROUTER_API_KEY
CODE_EMBED=$(jq -r '.runtime.octocode.update.code_embedding_model // "fastembed:all-MiniLM-L6-v2"' "$BJ")
TEXT_EMBED=$(jq -r '.runtime.octocode.update.text_embedding_model // "fastembed:all-MiniLM-L6-v2"' "$BJ")
# GPU EMBEDDING (octocode `local:` provider — OpenAI-shaped POST /v1/embeddings,
# see octolib/src/embedding/provider/local.rs). RUNNER-ONLY override of the two
# lines above, for the cloud-u-android semantic phase on the GCP GPU VM (owner
# decision 2026-09-03; declared in c_vps/vps_gcloud/src/terraform.json as
# gcp-gpu-embed, started/stopped around that one job by cgc-db-index.yml).
# CGC_LOCAL_EMBED_MODEL is the activation switch and is DELIBERATELY env-only —
# no build.json fallback: unlike USE_LLM/CODE_EMBED above, there is no safe
# default for an endpoint that is a VM stopped unless the caller just started
# it, so a bare local/dagu run of this script never reaches for the GPU. When
# it IS set, LOCAL_EMBED_API_URL / the batch size fall back to build.json's
# .runtime.octocode.update.gpu_embed (env still wins — same precedence as the
# LLM block above) so the workflow only has to carry the secret bearer token
# and (once known) the GH Actions repo variable for the URL.
GPU_EMBED_URL_DEFAULT=$(jq -r '.runtime.octocode.update.gpu_embed.embed_endpoint // empty' "$BJ")
GPU_EMBED_HEALTH_DEFAULT=$(jq -r '.runtime.octocode.update.gpu_embed.health_url // empty' "$BJ")
GPU_EMBED_BATCH_DEFAULT=$(jq -r '.runtime.octocode.update.gpu_embed.embeddings_batch_size // empty' "$BJ")
LOCAL_EMBED_API_URL="${LOCAL_EMBED_API_URL:-$GPU_EMBED_URL_DEFAULT}"
LOCAL_EMBED_API_KEY="${LOCAL_EMBED_API_KEY:-}"
LOCAL_EMBED_HEALTH_URL="${LOCAL_EMBED_HEALTH_URL:-$GPU_EMBED_HEALTH_DEFAULT}"
LOCAL_EMBED_BATCH_SIZE="${CGC_LOCAL_EMBED_BATCH_SIZE:-$GPU_EMBED_BATCH_DEFAULT}"
export LOCAL_EMBED_API_URL LOCAL_EMBED_API_KEY
if [ -n "${CGC_LOCAL_EMBED_MODEL:-}" ]; then
  CODE_EMBED="$CGC_LOCAL_EMBED_MODEL"
  TEXT_EMBED="$CGC_LOCAL_EMBED_MODEL"
  echo "[cgc-db] GPU embedding override active: CODE_EMBED=TEXT_EMBED=$CGC_LOCAL_EMBED_MODEL via ${LOCAL_EMBED_API_URL:-<unset>} (batch=${LOCAL_EMBED_BATCH_SIZE:-default}) — cgc-db-base:latest / the box stay on fastembed, see seed_base_if_missing()"
fi
# Pinned UPSTREAM octocode release (see ensure_octocode): version + per-arch sha256
# of the static musl tarball — the one pin the consumer image shares.
OCTO_VERSION=$(jq -r '.runtime.octocode.version // empty' "$BJ")
OCTO_REPO=$(jq -r '.runtime.octocode.release.repo // empty' "$BJ")
OCTO_ASSET=$(jq -r '.runtime.octocode.release.asset // empty' "$BJ")
# Data-driven exclude globs. octocode honours a gitignore-syntax `.noindex` file
# (in addition to `.gitignore`). dist/, vendor/, z_archive/ are git-COMMITTED here
# so `.gitignore` misses them — without this octocode embeds ~73% generated/vendored/
# archived junk, bloating the graph and tripling every index. One `.noindex` per repo.
NOINDEX_PATTERNS=$(jq -r '.runtime.octocode.noindex_patterns // [] | .[]' "$BJ" 2>/dev/null)
# Arch-aware binary: the arm runners (oci-apps aarch64) and x86 GHA fetch the same
# release, each its own arch asset verified against its own sha256.
case "$(uname -m)" in
  aarch64|arm64) OCTO_ARCH=aarch64 ;;
  *)             OCTO_ARCH=x86_64 ;;
esac
OCTO_SHA=$(jq -r --arg a "$OCTO_ARCH" '.runtime.octocode.release.sha256[$a] // empty' "$BJ")
if [ -z "$OCTO_VERSION" ] || [ -z "$OCTO_REPO" ] || [ -z "$OCTO_ASSET" ] || [ -z "$OCTO_SHA" ]; then
  echo "::error::[cgc-db] build.json .runtime.octocode.version / .release.{repo,asset,sha256.$OCTO_ARCH} incomplete — cannot pin the indexer binary"; exit 1
fi
CFG="$OCTO_HOME/config.toml"
TOKEN="${GHCR_TOKEN:-${GITHUB_TOKEN:-}}"
ACTOR="${GITHUB_ACTOR:-diegonmarcos}"
export HOME OCTOCODE_HOME="$OCTO_HOME"

# ── 0) FREEZE-PROOFING ──────────────────────────────────────────────────────
# Re-exec the ENTIRE producer inside a memory+CPU-bounded transient cgroup scope
# so a runaway `octocode index` / docker build is OOM-killed in isolation and can
# NEVER freeze the host: CPUQuota leaves a core free for sshd/WireGuard, and
# MemoryMax + MemorySwapMax=0 kill the JOB, not the VM. Runs as the invoking user
# (--uid/--gid → files stay user-owned) and inherits env through `sudo -E` so
# secrets pass via the environment, never argv. Limits are data-driven
# (build.json runtime.octocode.update.*). Degrades to nice/ionice when systemd-run
# or passwordless sudo is unavailable; CGC_NO_SANDBOX=1 opts out (e.g. ephemeral CI).
if [ -z "${CGC_SANDBOXED:-}" ] && [ "${CGC_NO_SANDBOX:-}" != "1" ]; then
  SELF="$HERE/${0##*/}"
  S_MEM=$(jq -r  '.runtime.octocode.update.mem_max    // "16G"'  "$BJ")
  S_SWAP=$(jq -r '.runtime.octocode.update.swap_max   // "0"'    "$BJ")
  S_CPUQ=$(jq -r '.runtime.octocode.update.cpu_quota  // "300%"' "$BJ")
  S_CPUW=$(jq -r '.runtime.octocode.update.cpu_weight // "10"'   "$BJ")
  S_IOW=$(jq -r  '.runtime.octocode.update.io_weight  // "10"'   "$BJ")
  # `-d /run/systemd/system` is the canonical "booted with systemd as init" test
  # (systemctl uses it). Inside a container (e.g. the gha-runner) systemd-run exists
  # but there is no system manager → scope creation dies with "Host is down". There
  # the container's own cpus/memory limits already provide freeze-safety, so fall
  # back to nice/ionice.
  if [ -d /run/systemd/system ] && command -v systemd-run >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    # --scope units have no ExecContext, so SupplementaryGroups= is rejected and
    # --uid/--gid drop the docker group → no daemon-socket access. Run with egid =
    # the docker socket's group (data-derived, not hardcoded) so the sandboxed
    # process keeps docker access while files stay owned by the invoking user.
    S_DGID="$(stat -c %g /var/run/docker.sock 2>/dev/null || id -g)"
    echo "[cgc-db] freeze-proof scope: MemoryMax=$S_MEM MemorySwapMax=$S_SWAP CPUQuota=$S_CPUQ CPUWeight=$S_CPUW IOWeight=$S_IOW gid=$S_DGID (cannot freeze host)"
    exec sudo -n -E systemd-run --scope --quiet --collect \
      --uid="$(id -u)" --gid="$S_DGID" \
      -p MemoryMax="$S_MEM" -p MemorySwapMax="$S_SWAP" \
      -p CPUQuota="$S_CPUQ" -p CPUWeight="$S_CPUW" -p IOWeight="$S_IOW" \
      env CGC_SANDBOXED=1 sh "$SELF" "$@"
  else
    echo "[cgc-db] freeze-proof: systemd-run/sudo unavailable — nice/ionice fallback"
    _pfx=""
    command -v nice   >/dev/null 2>&1 && _pfx="nice -n 19"
    command -v ionice >/dev/null 2>&1 && _pfx="$_pfx ionice -c2 -n7"
    exec env CGC_SANDBOXED=1 $_pfx sh "$SELF" "$@"
  fi
fi

# ── GUARANTEED NON-GIT SCRATCH DIR — STRAY-PREVENT, production incident (run
# 32572923354): packaging died with "expected exactly ONE project directory
# ... found 2". octocode initializes a project dir for the CWD's git repo on
# (apparently) ANY invocation, keyed by sha256(normalized origin URL) — so it
# is STABLE across runs for any git repo with a real origin. This script never
# `cd`s its own top-level shell anywhere (only inside `( cd ... && ... )`
# subshells for command substitution / the per-repo index below), so every
# BARE octocode call runs with this script's AMBIENT cwd — which in CI is the
# cloud-infra checkout itself ($GITHUB_WORKSPACE, a real git repo with a
# stable origin). A pre-index octocode call (version probe / config bootstrap,
# below) therefore silently stamped a stable stray <project_id>/ for
# cloud-infra into the octocode home BEFORE the target repo's own index ever
# ran, so packaging's exactly-one check (find_project_dir) saw that stray plus
# the target's own dir and hard-errored on every job.
# Every octocode invocation below that is NOT the actual 'octocode index' of a
# target repo (version probes, config bootstrap/mutation) is cd'd into this
# dir instead of running at the ambient cwd. Freshly created and deliberately
# left un-git-init'd — octocode's CWD-based project resolution has no git repo
# to key off here, so it cannot stamp anything. One dir for the whole script
# run (nothing inside it needs to persist between calls); created AFTER the
# freeze-proofing re-exec above so it belongs to the actual worker process.
CGC_SCRATCH="$(mktemp -d)"
trap 'rm -rf "$CGC_SCRATCH"' EXIT

# Never materialize Git-LFS content: cloud-u-android's element-x fork tracks
# images via LFS, and the runner's smudge filter fails ('git-lfs filter-process
# failed' on ac_cloud-matrix/docs/images-lfs/*.png) — which failed the WHOLE
# clone, and (because every matrix job clones every repo) every job with it.
# This was android's actual multi-day clone failure, invisible while clone
# stderr went to /dev/null. Indexing never needs LFS payloads (binaries are
# noindex'd anyway); pointer files are correct here.
export GIT_LFS_SKIP_SMUDGE=1

# 0b) ensure a FastEmbed-CAPABLE octocode on PATH. A binary built WITHOUT FastEmbed
#     (e.g. some nix/static builds — oci-apps' nix-profile octocode is one) fails
#     `octocode index` at runtime; the producer would then package the UNCHANGED
#     base = a silent no-op "update". So we VERIFY capability and, if the on-PATH
#     octocode lacks it, extract the pinned image binary (the *-fastembed-* images
#     are built with it). Pinned version keeps the DB schema compatible.
# FastEmbed probe. `models list` is the one read-only octocode command that names
# the compiled-in embedding providers. It still stamps a default config.toml into
# whatever home it resolves (0.22 does that on nearly every command), so it runs
# against a THROWAWAY XDG home, never $OCTO_HOME — a default config landing there
# (octocode's own jina code model, not build.json's) would make
# bootstrap_config_toml below keep it as if it were ours. The 0.12-era probe ran
# `octocode index` in an empty git repo for the same purpose; on 0.22 that also
# creates a stray project dir and starts a model download. Retired.
octocode_has_fastembed() {  # $1 = octocode binary path/name
  _t="$(mktemp -d)"
  _o="$( cd "$_t" && XDG_DATA_HOME="$_t" XDG_CONFIG_HOME="$_t" XDG_CACHE_HOME="$_t" "$1" models list 2>&1 || true )"
  rm -rf "$_t"
  case "$_o" in *"FastEmbed Provider"*) return 0 ;; *) return 1 ;; esac
}
# The octocode binary is the UPSTREAM static musl release, pinned by version +
# sha256 in build.json (.runtime.octocode.version / .release) — one pin shared with
# the consumer image (docker.native_build.cmd), asserted equal by
# 9_others/test/cgc-db-octocode-pin.test.sh. The DB schema follows the binary, so an
# on-PATH octocode is only accepted at exactly the pinned version. The 0.12.2-era
# per-arch GHCR images were hand-built once (2026-03-26) with no builder in this
# repo; upstream now ships static builds for both x86_64 and aarch64, so there is
# nothing left to build, mirror or docker-pull here.
ensure_octocode() {
  if command -v octocode >/dev/null 2>&1 \
     && [ "$(octocode --version 2>/dev/null | awk '{print $2}')" = "$OCTO_VERSION" ] \
     && octocode_has_fastembed octocode; then
    echo "[cgc-db] octocode: $OCTO_VERSION on PATH (FastEmbed ok)"; return 0
  fi
  bindir="${CGC_BIN:-$HOME/.local/bin}"; mkdir -p "$bindir"
  _asset=$(printf '%s' "$OCTO_ASSET" | sed "s/{version}/$OCTO_VERSION/g; s/{arch}/$OCTO_ARCH/g")
  _url="https://github.com/$OCTO_REPO/releases/download/$OCTO_VERSION/$_asset"
  echo "[cgc-db] fetching pinned octocode $OCTO_VERSION for $OCTO_ARCH — $_url"
  _tmp=$(mktemp -d)
  curl -fsSL --retry 5 --retry-delay 10 -o "$_tmp/$_asset" "$_url" \
    || { echo "::error::[cgc-db] octocode download failed: $_url"; exit 1; }
  _got=$(sha256sum "$_tmp/$_asset" | cut -c1-64)
  [ "$_got" = "$OCTO_SHA" ] \
    || { echo "::error::[cgc-db] octocode sha256 mismatch for $_asset — build.json .runtime.octocode.release.sha256.$OCTO_ARCH says $OCTO_SHA, download is $_got. Refusing an unverified indexer binary."; exit 1; }
  tar -xzf "$_tmp/$_asset" -C "$_tmp" octocode \
    && install -m 0755 "$_tmp/octocode" "$bindir/octocode" \
    || { echo "::error::[cgc-db] octocode tarball did not contain ./octocode"; exit 1; }
  rm -rf "$_tmp"
  PATH="$bindir:$PATH"; export PATH
  octocode_has_fastembed "$bindir/octocode" \
    || { echo "::error::[cgc-db] pinned octocode $OCTO_VERSION ($OCTO_ARCH) lacks FastEmbed"; exit 1; }
  echo "[cgc-db] octocode: $(octocode --version 2>/dev/null) (FastEmbed ok, upstream release, sha256 verified)"
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
# DETERMINISTIC MTIMES — the single reason indexing never converged.
#
# octocode's incremental reindex is mtime-based: it stores a per-file modification time in
# LanceDB (src/store/metadata.rs: "File metadata (per-file modification time, for
# incremental reindex)", store_file_metadata/get_file_mtime) and re-indexes any file whose
# filesystem mtime differs from the stored one. Git does NOT preserve mtimes, and this
# runner has no persistent /repos, so every run clones fresh and stamps EVERY file with the
# clone time. Octocode then correctly concludes the entire tree changed and re-embeds all
# of it — 1884 files for cloud-infra when only 16 actually changed since its last-indexed
# commit. That is the whole story behind the "5.2s/file" (it is real embedding work, not a
# stall) and behind the giants never finishing at any timeout setting.
#
# Fix: set each file's mtime to the timestamp of the last commit that touched it. That is
# deterministic across clones (verified: identical output over repeated runs) yet still
# changes exactly when the file's content changes, so genuine edits are still detected —
# a fixed constant would be stable but would also mask real changes forever.
# Equivalent to git-restore-mtime without taking the dependency.
restore_mtimes() {
  _rd="$1"
  [ -d "$_rd/.git" ] || return 0
  # One pass over history, newest first: the FIRST time a path appears is its last change.
  # Deleted paths still appear in history, so skip anything not present in the worktree —
  # touch would otherwise CREATE them and pollute the tree octocode walks.
  git -C "$_rd" log --pretty=format:'@%ct' --name-only --no-renames 2>/dev/null \
  | awk '/^@/{t=substr($0,2);next} NF && !seen[$0]++ {print t" "$0}' \
  | while read -r _ts _f; do
      [ -e "$_rd/$_f" ] || continue
      touch -h -d "@$_ts" "$_rd/$_f" 2>/dev/null || true
    done
}

ensure_repos() {
  # /repos is root-owned on a fresh runner — create + own it (sudo) if needed.
  mkdir -p "$REPOS_ROOT" 2>/dev/null || { sudo mkdir -p "$REPOS_ROOT" && sudo chown "$(id -un):$(id -gn)" "$REPOS_ROOT"; }
  # `jq | while read` runs the loop body in a SUBSHELL, so an `exit` inside it kills only
  # that subshell and the script sails on. Record failures in a marker file and act on it
  # after the pipeline, where we are back in the function's own shell.
  _clonefail="$REPOS_ROOT/.cgc-clone-failed"
  rm -f "$_clonefail"
  jq -r '.runtime.octocode.repo_map | to_entries[] | "\(.key) \(.value)"' "$BJ" | while read -r lname remote; do
    [ -n "$lname" ] || continue
    d="$REPOS_ROOT/$lname"
    # PRIVATE repos need a deploy key. $TOKEN here is the job's GITHUB_TOKEN, which is scoped
    # to THIS repo only — it can never clone a different private repo, so `clone cloud-data`
    # failed on every run and the repo was simply absent from the DB. Per-repo deploy keys are
    # the established pattern in this repo (CLOUD_DATA_DEPLOY_KEY). The lookup below is generic
    # — env CGC_DEPLOY_KEY_<local_dir, with - and . folded to _>; only the secret wiring in
    # cgc-db-index.yml is per-repo, because Actions resolves secrets by literal name only.
    unset GIT_SSH_COMMAND
    eval "_key=\${CGC_DEPLOY_KEY_$(printf '%s' "$lname" | tr -c '[:alnum:]' '_'):-}"
    if [ -n "$_key" ]; then
      mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
      _kf="$HOME/.ssh/cgc_${lname}"
      printf '%s\n' "$_key" > "$_kf" && chmod 600 "$_kf"
      # IdentitiesOnly: a deploy key grants ONE repo, so an agent offering several keys
      # authenticates as whichever is accepted first and then 403s on the wrong repo.
      export GIT_SSH_COMMAND="ssh -i $_kf -o IdentitiesOnly=yes -o StrictHostKeyChecking=no"
      url="git@github.com:diegonmarcos/${remote}.git"
    elif [ -n "$TOKEN" ]; then url="https://x-access-token:${TOKEN}@github.com/diegonmarcos/${remote}.git"
    else url="https://github.com/diegonmarcos/${remote}.git"; fi
    # octocode keys each project's DB dir on sha256(normalized origin URL)[..16], so
    # origin MUST NOT carry credentials. The token path above baked a per-run secret
    # into that hash, which meant (a) the id never matched what a consumer computes
    # from its own tokenless checkout — the per-repo images restored onto oci-apps
    # landed in dirs nothing would ever read, so every query silently built a fresh
    # empty index — and (b) the id changed whenever the token rotated, which is where
    # the monolith's drift of stale project-hash dirs came from. The SSH deploy-key
    # path was always fine (git@host:path normalizes to the same thing), so this only
    # ever bit the token repos, i.e. the public ones. Fetch with the credentialed URL
    # explicitly and keep origin canonical and stable.
    canon="https://github.com/diegonmarcos/${remote}.git"
    if [ -d "$d/.git" ]; then
      echo "[cgc-db] refresh $lname ← origin (full history for incremental detection)"
      git -C "$d" remote set-url origin "$canon" 2>/dev/null || true
      git -C "$d" fetch -q "$url" 2>/dev/null \
        && git -C "$d" reset --hard -q FETCH_HEAD 2>/dev/null \
        || echo "[cgc-db] WARN refresh $lname failed (using existing checkout)"
    else
      echo "[cgc-db] clone $lname ← $remote (full history for incremental detection)"
      # Full clone (no --depth): octocode stores the last-indexed commit in the DB and
      # diffs against it to find changed files. --depth 1 puts that stored commit outside
      # the shallow history → git can't resolve it → octocode re-indexes everything every
      # run. Full clone is small overhead; the embedding speedup is enormous (minutes vs hours).
      # Fail FAST, not four hours later. A missing repo is already fatal at the publish gate
      # ("refusing to publish an incomplete DB"), so warning here only buys a full pass of
      # embedding work before the same failure — and it read as a harmless warning for days
      # while cloud-data went unindexed. Same outcome, surfaced at minute one.
      # --filter=blob:none, NOT --depth: the comment above is right that shallow history
      # breaks incremental detection, but that argument is about COMMITS. A blobless clone
      # keeps the entire commit graph (so octocode's stored last-indexed commit still
      # resolves) and omits only historical file contents. --no-checkout defers populating
      # the working tree to an explicit step below — a plain `clone --filter=blob:none`
      # checks out immediately and pulls every blob the checkout touches in one big
      # up-front fetch anyway; splitting it out doesn't change what's fetched, but keeps
      # the two failure modes (fetch vs. checkout) distinguishable for the fallback below.
      # Runner disk is the binding constraint here — the DB alone restores to 16G on a
      # ~14G runner — so not downloading every blob of every past commit for seven repos
      # is free headroom. Falls back to a full clone if the remote refuses partial clone,
      # so this can never be the thing that fails a run.
      #
      # actions/checkout stamps a global `http.extraheader` (an Authorization token
      # scoped to THIS job's own repo, cloud-infra) into the runner's git config, and
      # that header inherits into every git command in the job — including clones of
      # DIFFERENT repos. Every ensure_repos clone is a foreign repo, so strip it
      # unconditionally: `-c http.extraheader=`. Credentials, when needed, travel in
      # $url (token-embedded https) or over SSH (deploy key), never via that header.
      # (The earlier guard `[ -z "$_key" ] && [ -z "$TOKEN" ]` was dead code — TOKEN
      # is always set at line ~188, so the strip never actually applied.)
      #
      # Clone stderr is CAPTURED and printed on failure. It used to be discarded
      # (2>/dev/null), which left cloud-u-android failing for days with zero signal
      # while three wrong theories (extraheader, auth, blobless) were chased. The
      # sed redacts any token embedded in the reported remote URL.
      _gitc="git -c http.extraheader="
      _cerr="$CGC_SCRATCH/clone-err.$$"
      if $_gitc clone -q --filter=blob:none --no-checkout "$url" "$d" 2>"$_cerr" \
        && $_gitc -C "$d" checkout -q 2>>"$_cerr"; then
        :
      elif rm -rf "$d" 2>/dev/null; $_gitc clone -q "$url" "$d" 2>>"$_cerr"; then
        :
      else
        sed 's/x-access-token:[^@]*@/x-access-token:***@/g' "$_cerr" | tail -8 >&2
        echo "::error::[cgc-db] clone $lname ← $remote failed — git stderr above (private repo without a CGC_DEPLOY_KEY_* secret?)"; : > "$_clonefail"
      fi
      rm -f "$_cerr"
      # Same reason as the refresh path: strip any credential back out of origin so
      # the project_id octocode derives is the canonical, consumer-matching one.
      git -C "$d" remote set-url origin "$canon" 2>/dev/null || true
    fi
    # NO sub-repo slicing (removed 2026-09-03). A sparse-checkout slice indexed with
    # --no-git does NOT get its own octocode project: 0.22 keys the project on
    # sha256(origin URL) whenever .git+origin exist (octolib path_to_id; --no-git only
    # skips the git-root check), so every slice of one origin lands in ONE project dir
    # and slices 2..n hit the "no commit changes, skipping" gate. Over-large repos
    # ratchet across runs instead: the timeout branch below publishes the partial DB
    # and octocode skips already-embedded files (file_metadata mtime + chunk hash).
    # After BOTH paths: a refresh (reset --hard) rewrites mtimes on every touched file just
    # as a clone does, so neither path can be trusted to carry stable mtimes on its own.
    _mt0=$(date +%s)
    restore_mtimes "$d"
    echo "[cgc-db] $lname · restored deterministic mtimes in $(( $(date +%s) - _mt0 ))s"
  done
  if [ -f "$_clonefail" ]; then
    rm -f "$_clonefail"
    echo "::error::[cgc-db] one or more repos failed to clone — refusing to spend a full indexing pass on a set that cannot publish"
    return 1
  fi
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

# SMART auto-noindex (GENERIC — zero hardcoded project paths). octocode CPU-pegs walking and
# GraphRAG-graphing binary/asset blobs (bootloader theme PNGs, fonts, media, compiled objects).
# Instead of a human maintaining a list of offending dirs, DETECT them: git's numstat vs the
# empty tree prints '-' for every binary file, so we aggregate binary-vs-total per directory
# and exclude any dir that is majority-binary. Regenerated each run → adapts as repos change.
# Thresholds are data-driven (build.json runtime.octocode.smart_noindex.*). Appends to .noindex.
smart_noindex() {
  _d="$1"; _nx="$_d/.noindex"
  [ -d "$_d/.git" ] || return 0
  command -v git >/dev/null 2>&1 || return 0
  _min=$(jq -r   '.runtime.octocode.smart_noindex.min_files    // 12'  "$BJ")
  _ratio=$(jq -r '.runtime.octocode.smart_noindex.binary_ratio // 0.5' "$BJ")
  _empty=$(git -C "$_d" hash-object -t tree /dev/null 2>/dev/null)
  [ -n "$_empty" ] || return 0
  _hits=$(git -C "$_d" diff --numstat "$_empty" HEAD 2>/dev/null | awk -v min="$_min" -v ratio="$_ratio" '
    { path=$3; if (path=="" || path !~ /\//) next;
      dir=path; sub(/\/[^\/]*$/,"",dir);      # immediate parent directory of the file
      tot[dir]++; if ($1=="-") bin[dir]++; }
    END { for (d in tot) if (tot[d]>=min && (bin[d]+0)/tot[d]>=ratio) print d"/"; }')
  [ -n "$_hits" ] || return 0
  # De-dup against whatever base patterns already landed in .noindex.
  printf '%s\n' "$_hits" | while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    grep -qxF "$_p" "$_nx" 2>/dev/null || printf '%s\n' "$_p" >> "$_nx"
  done
  echo "[cgc-db] $_d · smart-noindex auto-excluded binary-heavy dirs: $(printf '%s' "$_hits" | tr '\n' ' ')"
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
  _gha="$ROOT/1_cloud-configs/dist/build-gha.json"
  _target="$_host"
  if [ -f "$_gha" ]; then
    _wgip=$(jq -r --arg h "$_host" '.vms[$h].wg_ip // empty'  "$_gha" 2>/dev/null)
    _user=$(jq -r --arg h "$_host" '.vms[$h].user // "ubuntu"' "$_gha" 2>/dev/null)
    [ -n "$_wgip" ] && _target="$_user@$_wgip"
  fi
  # Safety guard: skip if source or destination identifiers are empty/missing.
  [ -n "$_vol" ] && [ -d "$OCTO_HOME" ] && [ -n "$(ls -A "$OCTO_HOME" 2>/dev/null)" ] \
    || { echo "[cgc-db] WARN propagate: empty OCTO_HOME/vol — skip"; return 0; }

  # Install rsync on the runner if missing (idempotent — no-op when already present).
  if ! command -v rsync >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    sudo apt-get install -y -qq rsync
  fi
  command -v rsync >/dev/null 2>&1 || { echo "[cgc-db] WARN propagate: rsync unavailable — skip"; return 0; }

  echo "[cgc-db] propagate → $_target (rsync $OCTO_HOME → /var/lib/docker/volumes/$_vol/_data/)"
  # Stop the MCP container so the volume is quiescent during sync.
  # shellcheck disable=SC2086
  ssh ${CGC_SSH_OPTS:-} "$_target" "sudo docker stop $_ctr" || true
  # Delta-only rsync into the live volume path via remote sudo.
  # shellcheck disable=SC2086
  if rsync -az --delete --rsync-path="sudo rsync" \
      -e "ssh ${CGC_SSH_OPTS:-}" \
      "$OCTO_HOME/" \
      "$_target:/var/lib/docker/volumes/$_vol/_data/"; then
    # shellcheck disable=SC2086
    ssh ${CGC_SSH_OPTS:-} "$_target" "sudo docker start $_ctr"
    echo "[cgc-db] propagate OK — $_host now serving the new DB (rsync)"
  else
    echo "[cgc-db] WARN propagate to $_host failed (host unreachable / mesh down)"
    # shellcheck disable=SC2086
    ssh ${CGC_SSH_OPTS:-} "$_target" "sudo docker start $_ctr" || true
    return 0
  fi
}

# STRAY-SELECT — ROBUST PROJECT-DIR SELECTION (per-repo mode). "exactly one dir under
# OCTO_HOME" (package.sh's find_project_dir) is the WRONG invariant to check
# BEFORE packaging: production incident (run 32572923354) — a stray project
# dir (see STRAY-PREVENT above for the leading cause; STRAY-SELECT is deliberately
# independent of STRAY-PREVENT actually catching every cause, since strays can in
# principle come from anywhere) sat in OCTO_HOME BEFORE this repo's own index
# ran, so find_project_dir saw two dirs and hard-errored instead of packaging.
#
# Snapshot the set of project dirs immediately BEFORE this repo's `octocode
# index`, and derive the target from the DIFF against the set immediately
# AFTER, instead of a bare count:
#   • exactly one NEW dir            → that is the target (a fresh index —
#                                       true whether OCTO_HOME started clean
#                                       or already had unrelated stray dirs;
#                                       those simply are not "new")
#   • zero new, exactly one TOUCHED  → that is the target (re-index of a
#                                       project dir this job already restored
#                                       from a prior per-repo checkpoint —
#                                       "touched" = some file under it has an
#                                       mtime newer than a marker stamped
#                                       right before the index ran)
#   • anything else                  → ambiguous; name the sets and hard-error
#                                       rather than guess (0 new+0 touched, or
#                                       >1 new, or >1 touched-with-no-new all
#                                       land here)
# Mirrors find_project_dir's fastembed/sentencetransformer exclusion (root-
# state model caches, never project dirs) so the two never disagree.
project_dirs_snapshot() {  # $1=OCTO_HOME → stdout: one dir name per line
  for _pds_e in "$1"/*; do
    [ -d "$_pds_e" ] || continue
    _pds_b="${_pds_e##*/}"
    case "$_pds_b" in fastembed|sentencetransformer) continue ;; esac
    printf '%s\n' "$_pds_b"
  done
}

resolve_project_dir() {  # $1=OCTO_HOME $2=BEFORE(newline list) $3=MARKER(mtime ref file) → stdout: dir name; rc!=0 on ambiguous
  _rpd_home="$1"; _rpd_before="$2"; _rpd_marker="$3"
  _rpd_after=$(project_dirs_snapshot "$_rpd_home")
  _rpd_new="" _rpd_n_new=0
  for _rpd_d in $_rpd_after; do
    printf '%s\n' "$_rpd_before" | grep -qxF "$_rpd_d" || { _rpd_new="$_rpd_new $_rpd_d"; _rpd_n_new=$((_rpd_n_new + 1)); }
  done
  if [ "$_rpd_n_new" -eq 1 ]; then
    printf '%s\n' "${_rpd_new# }"
    return 0
  fi
  if [ "$_rpd_n_new" -eq 0 ]; then
    _rpd_touched="" _rpd_n_touched=0
    for _rpd_d in $_rpd_after; do
      # Preexisting dir (present before too) whose contents changed since $_rpd_marker was stamped.
      [ -n "$(find "$_rpd_home/$_rpd_d" -newer "$_rpd_marker" -print -quit 2>/dev/null)" ] \
        && { _rpd_touched="$_rpd_touched $_rpd_d"; _rpd_n_touched=$((_rpd_n_touched + 1)); }
    done
    if [ "$_rpd_n_touched" -eq 1 ]; then
      printf '%s\n' "${_rpd_touched# }"
      return 0
    fi
    echo "::error::[cgc-db] ambiguous project-dir diff under $_rpd_home: before=[$(printf '%s' "$_rpd_before" | tr '\n' ' ')] after=[$(printf '%s' "$_rpd_after" | tr '\n' ' ')] new=0 touched=$_rpd_n_touched[$(printf '%s' "$_rpd_touched" | tr '\n' ' ')] — cannot determine which dir this index produced" >&2
    return 1
  fi
  echo "::error::[cgc-db] ambiguous project-dir diff under $_rpd_home: before=[$(printf '%s' "$_rpd_before" | tr '\n' ' ')] after=[$(printf '%s' "$_rpd_after" | tr '\n' ' ')] new=$_rpd_n_new[$(printf '%s' "$_rpd_new" | tr '\n' ' ')] — expected exactly one new dir" >&2
  return 1
}

# Checkpoint-push after one repo. CGC_PACKAGE_MODE=per-repo (matrix CI) packages
# ONLY that repo's own project dir into its OWN GHCR image; the default
# "monolith" mode keeps packaging the WHOLE octocode home into the single
# shared db_publish.image, unchanged. Same script either way —
# cloud-cgc-db-package.sh auto-detects repo/base/monolith packaging mode from
# the image name (${IMAGE##*/} — "cgc-db-<repo>" vs "cgc-db-base" vs anything
# else), so the only difference here is WHICH image name is passed.
# REPO_PREFIX/REPO_TAG are set once above (per-repo restore-base branch) —
# reused here rather than re-reading build.json per repo.
# CGC_PROJECT_DIR (STRAY-SELECT) — when the per-repo loop below has already resolved
# THIS checkpoint's project dir via the before/after diff (_proj_resolved),
# pass it through so package.sh's own find_project_dir (an exactly-one count
# over the WHOLE home, which is exactly the fragile invariant STRAY-SELECT replaces)
# is bypassed for this call. Empty when unresolved (e.g. monolith mode, where
# packaging tars the whole home and never looks at project dirs at all) —
# package.sh falls back to find_project_dir precisely as before for any
# caller that does not set it.
checkpoint_publish() {  # $1 = repo local name
  if [ "${CGC_PACKAGE_MODE:-monolith}" = "per-repo" ]; then
    CGC_BUILD_JSON="$BJ" CGC_PROJECT_DIR="${_proj_resolved:-}" sh "$HERE/cloud-cgc-db-package.sh" "$OCTO_HOME" "${REPO_PREFIX}${1}" "$REPO_TAG"
  else
    CGC_BUILD_JSON="$BJ" sh "$HERE/cloud-cgc-db-package.sh" "$OCTO_HOME" "$IMAGE" "$TAG"
  fi
}

# BOOTSTRAP config.toml (per-repo mode only). Before the versioned base image
# exists on GHCR (the first cycle after every octocode bump) the base restore is a
# no-op and OCTO_HOME has no config.toml; an `octocode index` in that state would
# write octocode's OWN defaults (production incident 2026-08-21, run 32502667627:
# cloud models needing VOYAGE_API_KEY, zero files indexed). The file is generated
# by the pinned octocode itself — a hand-written template cannot track the schema
# (0.22 refuses the 0.12-era v1 file outright: "missing field `quantization`" —
# measured), while `octocode config --<flag>` always writes the loader's own
# current version. XDG_DATA_HOME is aligned to $OCTO_HOME's parent above, so the
# write lands exactly at $CFG; that is verified, never assumed. build.json's
# embedding models go in on the same call — a wrong/missing model here silently
# drop_tables data on a later restore (see cloud-cgc-db-package.sh's base DESC).
bootstrap_config_toml() {
  [ -f "$CFG" ] && return 0
  mkdir -p "$(dirname "$CFG")"
  ( cd "$CGC_SCRATCH" && octocode config --model "$LLM" \
      --code-embedding-model "$CODE_EMBED" --text-embedding-model "$TEXT_EMBED" ) >/dev/null 2>&1 || true
  [ -f "$CFG" ] || { echo "::error::[cgc-db] octocode config did not create $CFG (XDG_DATA_HOME=${XDG_DATA_HOME:-unset}) — nothing to index with"; exit 1; }
  # Parity with what every consumer was validated against: reranker + hybrid OFF
  # (0.22 turns both on by default; the reranker pulls a ~1GB jina model at query
  # time) and graphrag OFF/no-LLM until 4a/4b decide per phase. Section-scoped so
  # the same key names under [graphrag.llm] / [search.reasoning] are untouched.
  awk '
    /^\[/ { sec = $0 }
    (sec == "[search.reranker]" || sec == "[search.hybrid]" || sec == "[graphrag]") && /^enabled[[:space:]]*=/ { print "enabled = false"; next }
    sec == "[graphrag]" && /^use_llm[[:space:]]*=/ { print "use_llm = false"; next }
    { print }' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
  echo "[cgc-db] bootstrapped config.toml with octocode $OCTO_VERSION (embedding $CODE_EMBED / $TEXT_EMBED, llm $LLM, reranker/hybrid off)"
}

# AUTO-SEED the shared base image (per-repo mode only) — the other half of the
# 2026-08-21 bootstrap incident (see bootstrap_config_toml() above). Before this,
# cgc-db-base:latest had to be seeded OUT OF BAND by a human running
# cloud-cgc-db-package.sh once; every matrix cycle before that seed hit the same
# missing-config crash. Once THIS job has published a checkpoint, OCTO_HOME holds
# at minimum a valid config.toml (bootstrap-written above, or already restored) —
# package+push it as the base image the same way a human seed would, via
# cloud-cgc-db-package.sh's existing "base" mode (auto-detected from the
# cgc-db-base image name — see that script's header). Its build_base_tar()
# already tolerates a PARTIAL root state (config.toml alone is enough; it only
# errors if NONE of config.toml/fastembed/sentencetransformer exist), so this is
# safe even on the very first repo of the very first cycle.
#
# GUARD: BASE_SEEDED (reset once per job run, above the repo loop) — only the
# FIRST repo in THIS job attempts a seed; a second attempt in the same job would
# just re-push the same root state for no benefit. RACES BETWEEN PARALLEL MATRIX
# JOBS are deliberately left unguarded: every job in a cycle restores the SAME
# (missing) base and indexes with the SAME build.json models, so their
# config.toml/fastembed content converges to the same bytes regardless of which
# repo produced it — concurrent pushes to cgc-db-base:latest are idempotent,
# last-write-wins on content that is the same either way.
seed_base_if_missing() {
  [ "$BASE_SEEDED" = "1" ] && return 0
  BASE_SEEDED=1
  # GPU-EMBED GUARD — see CGC_LOCAL_EMBED_MODEL above. This job's OCTO_HOME
  # config.toml carries local:nomic-embed-text while the override is active;
  # seeding $BASE_IMAGE from it would publish that model into the shared base
  # that every consumer restores — including this box's own cloud-cgc-pub-mcp/
  # cloud-cgc-pvt-mcp, which embed search QUERIES and must stay on fastembed.
  # Refuse instead: the base stays whatever it already was (present, per the
  # docker manifest check below, in every run that matters — this only bites
  # the astronomically rare case of a GPU-embed run landing on the very first
  # cycle after an octocode version bump, before any fastembed job has re-
  # seeded the base) and a later non-GPU job seeds it for real if ever needed.
  if [ -n "${CGC_LOCAL_EMBED_MODEL:-}" ]; then
    echo "::warning::[cgc-db] CGC_LOCAL_EMBED_MODEL is set — refusing to auto-seed $BASE_IMAGE from this job's config.toml (would leak '$CGC_LOCAL_EMBED_MODEL' into the shared base/box, which must stay fastembed). Skipping; a fastembed job will seed it if it is genuinely still missing."
    return 0
  fi
  if docker manifest inspect "$BASE_IMAGE" >/dev/null 2>&1; then
    echo "[cgc-db] base image $BASE_IMAGE already on GHCR — skip auto-seed"
    return 0
  fi
  _sbm_img="${BASE_IMAGE%:*}"
  case "$BASE_IMAGE" in *:*) _sbm_tag="${BASE_IMAGE##*:}" ;; *) _sbm_tag="latest" ;; esac
  echo "[cgc-db] $BASE_IMAGE missing on GHCR — auto-seeding from this job's octocode home"
  if CGC_BUILD_JSON="$BJ" sh "$HERE/cloud-cgc-db-package.sh" "$OCTO_HOME" "$_sbm_img" "$_sbm_tag"; then
    echo "[cgc-db] auto-seed OK — $BASE_IMAGE published"
  else
    echo "::warning::[cgc-db] auto-seed of $BASE_IMAGE failed — next job's bootstrap will retry"
  fi
}

# ── run ───────────────────────────────────────────────────────────────────
# GHCR auth FIRST — the base / per-repo checkpoint images below are GHCR pulls, so
# docker must be logged in before any of them. (ensure_octocode itself no longer
# needs docker: the indexer binary comes straight from the upstream release.)
ensure_ghcr_auth
ensure_octocode
ensure_repos

# SMALLEST-FIRST. index_repos is authoring order, not run order, and it happened to put
# the two largest repos first — both blew their repo_timeout_min, consumed the whole
# max_minutes budget, and the remaining five were deferred with "deferring front (+rest)".
# Net effect on 2026-08-20: 180m spent, zero repos indexed, nothing published, while five
# repos that finish in minutes never got a turn. Ordering by tracked-file count ascending
# makes every run publish the cheap repos FIRST, so a giant that cannot finish can only
# ever cost itself its own slot — never the whole cycle. Measured from the clone (git
# ls-files), not declared in build.json, so it stays true as repos grow. Ties keep
# authoring order; a repo whose count cannot be read sorts last rather than blocking.
order_repos_by_size() {
  for _r in $REPOS; do
    _n=$(git -C "$REPOS_ROOT/$_r" ls-files 2>/dev/null | wc -l)
    [ "$_n" -gt 0 ] 2>/dev/null || _n=99999999
    printf '%s\t%s\n' "$_n" "$_r"
  done | sort -n -s -k1,1 | cut -f2
}
REPOS=$(order_repos_by_size)
echo "[cgc-db] index order (smallest first): $(printf '%s' "$REPOS" | tr '\n' ' ')"

# 3) restore the incremental base from GHCR. The producer is INCREMENTAL-ONLY —
# it must NEVER full-build from scratch (octocode's GraphRAG full build is ~12h,
# O(N²) relationships). The base is created ONCE by a seed: cloud-cgc-db-package.sh
# of an already-built octocode DB, or a prod-volume snapshot. Refuse without a base.
#
# CGC_PACKAGE_MODE=per-repo (matrix CI): OCTO_HOME is a FRESH per-job dir, and
# there is no monolith base to refuse-without — restore the SHARED base image
# (config.toml + fastembed/ + sentencetransformer/ caches, NOT the 15G monolith)
# then, layered on top, THIS repo's own prior per-repo checkpoint image if one
# exists. A repo with no prior image starts empty — that is the documented
# first-build case (per-repo images bootstrap from empty), not an error.
mkdir -p "$OCTO_HOME"
if [ "${CGC_PACKAGE_MODE:-monolith}" = "per-repo" ]; then
  BASE_IMAGE=$(jq -r '.per_repo_publish.base_image // "ghcr.io/diegonmarcos/cgc-db-base:latest"' "$BJ")
  REPO_PREFIX=$(jq -r '.per_repo_publish.image_prefix // "ghcr.io/diegonmarcos/cgc-db-"' "$BJ")
  REPO_TAG=$(jq -r '.per_repo_publish.tag // "latest"' "$BJ")
  sh "$HERE/cloud-cgc-db-pull.sh" "$OCTO_HOME" "$BASE_IMAGE" || true
  for _r in $REPOS; do
    # FORCED graphrag = FULL re-index: do not layer this repo's prior checkpoint.
    # octocode 0.12.2 feeds its graph builder only the files the current update
    # actually processes, and TWO metadata tables in the prior image gate that
    # set down to "changed since last run" (git_metadata.lance by commit,
    # file_metadata.lance by content hash) — so force-dropping graphrag_* on
    # top of a restored checkpoint rebuilt the graph from a 29-file sliver of a
    # 1000-file corpus (run 32664198030, measured). Starting from the shared
    # base instead (config + embedder caches, no blocks, no metadata) makes the
    # update process EVERY file, which is the only full-graph path this octocode
    # has. Embeddings recompute — that cost is the per-repo semantic pass, not
    # the ~12h monolith figure, and the 8-wide matrix absorbs it. Safety is
    # unchanged: preflight failure aborts before package/push, so the prior
    # image on GHCR survives until a full replacement is actually built.
    # ...and a forced SEMANTIC run just the same: `force` is the documented lever
    # "after an INDEXER change" (cgc-db.yml), and an octocode bump is exactly that —
    # layering a checkpoint written by another octocode version under the new
    # binary is the one thing that must never happen (the DB schema follows the
    # binary). Forced means from base, in both phases.
    if [ "${CGC_FORCE:-0}" = "1" ]; then
      echo "[cgc-db] CGC_FORCE — skipping prior checkpoint of $_r: full re-index from base (USE_LLM=$USE_LLM)"
      continue
    fi
    CGC_PULL_MERGE=1 sh "$HERE/cloud-cgc-db-pull.sh" "$OCTO_HOME" "${REPO_PREFIX}${_r}:${REPO_TAG}" || true
  done
else
  sh "$HERE/cloud-cgc-db-pull.sh" "$OCTO_HOME" || true
  if [ -z "$(ls -A "$OCTO_HOME" 2>/dev/null | grep -v '^config\.toml$')" ]; then
    echo "::error::no GHCR DB base restored — refusing a from-scratch full build (~12h)."
    echo "::error::seed once first: sh $HERE/cloud-cgc-db-package.sh <existing-octocode-home> $IMAGE $TAG"
    exit 1
  fi
fi
# FIX 1 (per-repo mode only — see bootstrap_config_toml() above for why): must run
# BEFORE the generic fallback below, which is a documented no-op for this exact
# case (kept, untouched, as the monolith-mode safety net it always was).
[ "${CGC_PACKAGE_MODE:-monolith}" = "per-repo" ] && bootstrap_config_toml
[ -f "$CFG" ] || ( cd "$CGC_SCRATCH" && octocode config ) >/dev/null 2>&1 || true

# 4a) force the GraphRAG LLM phase on (use_llm + model). awk, never sed.
# STRAY-PREVENT: `octocode config` here (and in the else branch below) is a bare,
# non-index octocode invocation — cd into CGC_SCRATCH (see its definition
# above) rather than the script's ambient cwd, so it cannot stamp a project
# dir for the CI checkout. This is best-effort only: the awk block right
# after each call is what actually enforces the resulting config.toml state
# either way, so this cd change cannot regress correctness even if the CLI
# call itself behaves differently outside a git repo.
if [ "$USE_LLM" = "true" ] && [ -f "$CFG" ]; then
  ( cd "$CGC_SCRATCH" && octocode config --model "$LLM" --graphrag-enabled true ) >/dev/null 2>&1 || true
  awk -v m="$LLM" '
    /^\[graphrag\]/                                { in_gr=1 }
    /^\[/ && !/^\[graphrag\]/                      { in_gr=0 }
    # [llm] model is what the architectural-analysis pass uses, and the old
    # bootstrap hardcoded a fixed `openrouter:openai/gpt-4o-mini` there,
    # ignoring the declared model entirely. octocode picks its provider from that
    # prefix and reads the env pair that provider names, which nothing exported,
    # so it reported "LLM client not initialized" regardless. Every DB
    # pulled from an existing image still carries that line, so rewriting it
    # here is what actually repairs the inherited configs.
    /^\[llm\]/                                     { in_llm=1 }
    /^\[/ && !/^\[llm\]/                          { in_llm=0 }
    in_llm && /^[[:space:]]*model[[:space:]]*=/    { print "model = \"" m "\""; next }
    in_gr && /^[[:space:]]*enabled[[:space:]]*=/   { print "enabled = true"; next }
    /^[[:space:]]*use_llm[[:space:]]*=/            { print "use_llm = true"; next }
    /^[[:space:]]*description_model[[:space:]]*=/  { print "description_model = \"" m "\""; next }
    /^[[:space:]]*relationship_model[[:space:]]*=/ { print "relationship_model = \"" m "\""; next }
    { print }' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
  grep -q "use_llm = true" "$CFG" 2>/dev/null || printf '\n[graphrag]\nenabled = true\nuse_llm = true\n' >> "$CFG"
  echo "[cgc-db] GraphRAG LLM = $LLM (enabled=true use_llm=true)"
  # PREFLIGHT — fail loudly, never degrade silently. octocode treats an
  # unreachable/unauthenticated LLM as a WARNING and keeps going, emitting a
  # graph of structural `sibling_module` edges only. That is indistinguishable
  # from success in the exit code, so the run "passed" and shipped a DB with no
  # semantic relationships at all. If the graphrag phase was explicitly asked
  # for, an LLM it cannot reach is a hard error.
  # The model string is no longer a literal in this script -- it comes from
  # build.json, and its prefix is what selects the provider. A missing key would
  # write `model = "null"`, octocode would fail to resolve a provider, and we
  # would be right back at a silent structural-only graph.
  case "$LLM" in
    ""|null)
      echo "::error::[cgc-db] .runtime.octocode.update.llm_model is unset in $BJ — the provider prefix is what octocode resolves its LLM from"
      exit 1 ;;
  esac
  # WHICH url matters is decided by the model prefix, so check the one this
  # model actually resolves. Hardcoding the openai var passed a model routed
  # through ollama even with no ollama url declared -- a preflight that green-lights
  # the exact config it exists to reject.
  case "$LLM" in
    openrouter:*) _llm_url="$OPENROUTER_API_URL"; _llm_field="openrouter_api_url" ;;
    ollama:*)     _llm_url="$OLLAMA_API_URL";     _llm_field="ollama_api_url" ;;
    *)            _llm_url="$OPENAI_API_URL";     _llm_field="openai_api_url" ;;
  esac
  # The url has to be the full completions path, not the /v1 base: with the base,
  # octocode builds a client fine and every call then comes back empty ("Failed to
  # parse JSON from response"), which degrades exactly like no client at all.
  case "$_llm_url" in
    ""|*/chat/completions) ;;
    *) echo "::warning::[cgc-db] .runtime.octocode.llm.$_llm_field is '$_llm_url' — octocode posts to it verbatim and a bare /v1 base returns an empty body" ;;
  esac
  if [ -z "$_llm_url" ]; then
    echo "::error::[cgc-db] graphrag phase requested but .runtime.octocode.llm.$_llm_field is unset in $BJ — $LLM resolves to it, and octocode would silently produce structural-only edges"
    exit 1
  fi
  if [ -n "$LLM_HEALTH_URL" ]; then
    # Retry: a WireGuard tunnel brought up seconds ago has not necessarily
    # completed a handshake with the far peer yet, and a first-packet timeout
    # there is normal rather than a fault.
    _lh=0; _llm_ok=0; _lerr=""
    while [ "$_lh" -lt 6 ]; do
      _lh=$((_lh + 1))
      _lerr=$(curl -fsS -m 15 -o /dev/null "$LLM_HEALTH_URL" 2>&1) && { _llm_ok=1; break; }
      [ "$_lh" -lt 6 ] && sleep 10
    done
    if [ "$_llm_ok" = "1" ]; then
      echo "[cgc-db] LLM endpoint healthy: $LLM_HEALTH_URL (attempt $_lh)"
    else
      # Say WHICH layer failed. "unreachable" alone sent the last investigation
      # after a missing credential that never existed; the mesh was the problem.
      _lhost=$(printf '%s' "$LLM_HEALTH_URL" | sed -e 's|^[a-z]*://||' -e 's|[:/].*$||')
      echo "::error::[cgc-db] graphrag phase requested but the LLM endpoint failed its health check: $LLM_HEALTH_URL"
      echo "[cgc-db] curl said: ${_lerr:-<no output>}"
      echo "[cgc-db] mesh triage for $_lhost (the endpoint is mesh-only, so this distinguishes 'no route' from 'port filtered'):"
      ping -c 2 -W 3 10.0.0.1 >/dev/null 2>&1 && echo "[cgc-db]   hub 10.0.0.1: reachable" || echo "[cgc-db]   hub 10.0.0.1: NO — WireGuard is not carrying traffic at all"
      ping -c 2 -W 3 "$_lhost" >/dev/null 2>&1 && echo "[cgc-db]   $_lhost icmp: reachable" || echo "[cgc-db]   $_lhost icmp: no reply"
      if command -v nc >/dev/null 2>&1; then
        nc -z -w 5 "$_lhost" 22 >/dev/null 2>&1 && echo "[cgc-db]   $_lhost:22 open — the host IS routable, so the LLM port specifically is blocked" || echo "[cgc-db]   $_lhost:22 closed too — this is routing, not a port filter"
      fi
      echo "[cgc-db] refusing to ship a structural-only graph."
      exit 1
    fi
  fi

  # FORCE INVALIDATES THE GRAPH, NOT THE EMBEDDINGS.
  # octocode gates its two passes separately: it skips the chunk reindex when the
  # commit is unchanged ("No commit changes since last index, skipping reindex"),
  # and it builds the graph only when it finds none ("No GraphRAG nodes found in
  # database"). So once a degraded run has written a structural-only graph at this
  # HEAD, every later run finds a graph present and leaves it alone -- the repair
  # would silently never happen, which is the same silent-degradation shape this
  # phase already guards against elsewhere.
  #
  # CGC_FORCE means "the INDEXER changed, so this DB is stale at an unchanged
  # HEAD". In per-repo mode the real force mechanism now lives at the restore
  # step above: the prior checkpoint is never layered in, so this home holds no
  # graph (or metadata) to begin with and the drop below finds nothing — kept
  # anyway as the monolith-mode fallback, where a restored home DOES carry the
  # stale graph and dropping graphrag_* while keeping code_blocks.lance is
  # still the right (and only affordable) repair for a 15G monolith.
  #
  # Deliberately placed AFTER the preflight: the graph is only ever destroyed once
  # the LLM endpoint has answered, so we cannot delete a graph we then cannot
  # rebuild. A failure after this point aborts before package/push anyway, so the
  # DB on GHCR is never the damaged one.
  if [ "${CGC_FORCE:-0}" = "1" ]; then
    _purged=0
    for _t in "$OCTO_HOME"/*/storage/graphrag_nodes.lance \
              "$OCTO_HOME"/*/storage/graphrag_relationships.lance \
              "$OCTO_HOME"/*/storage/graphrag_git_metadata.lance; do
      [ -e "$_t" ] || continue
      rm -rf "$_t" && _purged=$((_purged + 1))
    done
    echo "[cgc-db] CGC_FORCE=1 — dropped $_purged graphrag table(s); embeddings kept, graph will rebuild"
  fi
else
  # GPU EMBEDDING PREFLIGHT — same posture as the LLM preflight above: fail
  # loudly before doing anything expensive rather than let octocode degrade
  # silently. octocode's local: provider probes the embedding dimension from
  # a live response at first use (LocalEmbeddingProvider::new), so a dead/mis-
  # authed endpoint would otherwise surface as a cryptic mid-index failure (or
  # worse, a partially-written project if it dies after some chunks embedded).
  # POST a real one-text embedding request — this also verifies the bearer
  # token and that the model is pulled, not just that the port answers.
  if [ -n "${CGC_LOCAL_EMBED_MODEL:-}" ]; then
    if [ -z "$LOCAL_EMBED_API_URL" ]; then
      echo "::error::[cgc-db] CGC_LOCAL_EMBED_MODEL=$CGC_LOCAL_EMBED_MODEL but LOCAL_EMBED_API_URL is unset (neither env nor build.json .runtime.octocode.update.gpu_embed.embed_endpoint) — octocode's local: provider has nowhere to POST"
      exit 1
    fi
    _ge=0; _ge_ok=0; _ge_err=""
    while [ "$_ge" -lt 6 ]; do
      _ge=$((_ge + 1))
      _ge_err=$(curl -fsS -m 30 -o /dev/null \
        -H "Content-Type: application/json" \
        ${LOCAL_EMBED_API_KEY:+-H "Authorization: Bearer $LOCAL_EMBED_API_KEY"} \
        -d "{\"model\":\"${CGC_LOCAL_EMBED_MODEL#local:}\",\"input\":[\"preflight\"]}" \
        "$LOCAL_EMBED_API_URL" 2>&1) && { _ge_ok=1; break; }
      [ "$_ge" -lt 6 ] && sleep 10
    done
    if [ "$_ge_ok" = "1" ]; then
      echo "[cgc-db] GPU embedding endpoint healthy: $LOCAL_EMBED_API_URL (attempt $_ge, model ${CGC_LOCAL_EMBED_MODEL#local:})"
    else
      echo "::error::[cgc-db] semantic phase requested CGC_LOCAL_EMBED_MODEL=$CGC_LOCAL_EMBED_MODEL but the endpoint failed preflight: $LOCAL_EMBED_API_URL"
      echo "[cgc-db] curl said: ${_ge_err:-<no output>}"
      echo "[cgc-db] is the gcp-gpu-embed VM started? (devops_vm_start gcp-gpu-embed / the workflow's start step before this job)"
      exit 1
    fi
  fi

  # Force structural-only to MATCH build.json (use_llm=false). The base config.toml
  # may carry a STALE `use_llm = true` + an unreachable LLM model (e.g. ollama:*),
  # which makes octocode block on per-batch LLM timeouts → glacial. Previously this
  # branch only PRINTED "structural-only" without disabling it. Disable it for real.
  if [ -f "$CFG" ]; then
    ( cd "$CGC_SCRATCH" && octocode config --graphrag-enabled false --code-embedding-model "$CODE_EMBED" --text-embedding-model "$TEXT_EMBED" ) >/dev/null 2>&1 || true
    awk '
      /^\[graphrag\]/                              { in_gr=1 }
      /^\[/ && !/^\[graphrag\]/                    { in_gr=0 }
      in_gr && /^[[:space:]]*enabled[[:space:]]*=/ { print "enabled = false"; next }
      /^[[:space:]]*use_llm[[:space:]]*=/          { print "use_llm = false"; next }
      { print }' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    grep -q "use_llm = false" "$CFG" 2>/dev/null || printf '\n[graphrag]\nenabled = false\nuse_llm = false\n' >> "$CFG"
    # embeddings_batch_size — no CLI flag (verified against octocode's config
    # command source), config.toml [index] only. GPU-embed only: raising this
    # for the fastembed/CPU repos is untested and out of scope here. awk, never
    # sed (see reference_awk-not-sed-secrets.md).
    if [ -n "${CGC_LOCAL_EMBED_MODEL:-}" ] && [ -n "$LOCAL_EMBED_BATCH_SIZE" ]; then
      awk -v n="$LOCAL_EMBED_BATCH_SIZE" '
        /^\[index\]/                                        { in_idx=1 }
        /^\[/ && !/^\[index\]/                              { in_idx=0 }
        in_idx && /^[[:space:]]*embeddings_batch_size[[:space:]]*=/ { print "embeddings_batch_size = " n; next }
        { print }' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
      echo "[cgc-db] GPU embedding: embeddings_batch_size=$LOCAL_EMBED_BATCH_SIZE"
    fi
  fi
  echo "[cgc-db] GraphRAG structural-only (enabled=false use_llm=false forced — no LLM calls)"
fi

# 4b) SMART INCREMENTAL index — per-repo change-GATED + checkpoint-PUSHED.
#
#   Why every prior run got CANCELLED: one job re-ran `octocode index` for ALL 6
#   repos every time (~2.5h each incl. the GraphRAG relationship pass, which is
#   O(graph) regardless of how few files changed) → ~15h → past the runner cap →
#   cancelled BEFORE the single end-of-run push → GHCR DB never advanced.
#
#   Three engine-level fixes, all data-driven, NO topology change (still one job):
#     • CHANGE GATE  — skip `octocode index` entirely for any repo whose git HEAD
#       equals the commit last indexed into THIS DB. The last-indexed commit per
#       repo lives in a manifest INSIDE the octocode home, so it is packaged and
#       pulled with the DB (single source of truth, reproducible). Between twice-
#       daily runs most repos are unchanged → seconds, not hours.
#     • CHECKPOINT PUSH — package+push after EACH changed repo. A later cancel now
#       loses at most the in-flight repo; every finished repo is already on GHCR
#       AND recorded in the manifest, so the next run skips it and resumes the
#       rest. The pipeline self-heals across runs instead of restarting from zero.
#     • TIME BUDGET — stop taking on NEW repos past runtime.octocode.update.max_minutes
#       and exit cleanly (already-pushed via checkpoints); the next run resumes the
#       remainder via the change gate. We are never killed mid-repo after the budget.
command -v git >/dev/null 2>&1 && git config --global --add safe.directory '*' >/dev/null 2>&1 || true

# PER-PHASE manifest: each phase (semantic / graphrag) tracks its OWN last-indexed
# commit per repo, so the change gate for one phase is independent of the other.
# Without this, the semantic phase advances HEAD in a single shared manifest and the
# graphrag phase — which needs to enrich the SAME commit with LLM relationships —
# would be skipped as "unchanged" and never run. CGC_MANIFEST_PHASE selects the file
# (semantic → .cgc-manifest-semantic.json, graphrag → .cgc-manifest-graphrag.json).
# Both manifests live inside OCTO_HOME so they are packaged into and pulled from the
# GHCR DB snapshot, travelling with the DB (single reproducible source of truth).
# Falls back to the legacy single-manifest filename when no phase is set (bare local
# invocation), preserving the pre-two-phase behaviour.
MANIFEST_PHASE="${CGC_MANIFEST_PHASE:-}"
if [ -n "$MANIFEST_PHASE" ]; then
  MANIFEST="$OCTO_HOME/.cgc-manifest-${MANIFEST_PHASE}.json"
else
  MANIFEST="$OCTO_HOME/.cgc-index-manifest.json"
fi
echo "[cgc-db] phase=${MANIFEST_PHASE:-default} USE_LLM=$USE_LLM manifest=$(basename "$MANIFEST")"
[ -s "$MANIFEST" ] || echo '{}' > "$MANIFEST"
BUDGET_MIN=$(jq -r '.runtime.octocode.update.max_minutes // 330' "$BJ")
REPO_TIMEOUT_MIN=$(jq -r '.runtime.octocode.update.repo_timeout_min // "0"' "$BJ")
START_TS=$(date +%s)
PUSHED=0
# FIX 2 guard (per-repo mode) — see seed_base_if_missing() above: only the FIRST
# repo in this job attempts a base-image seed, even if this job indexes more than
# one repo (CGC_INDEX_REPOS can list several). Meaningless/unused in monolith mode.
BASE_SEEDED=0
# Outcome tally. "no repo changed — DB already current" was printed on 2026-08-20 after two
# repos had TIMED OUT and five were deferred: a green log during a six-day outage. Count
# every terminal state per repo so the summary can never claim currency it has not earned.
N_INDEX=0; N_SKIP=0; N_TIMEOUT=0; N_DEFER=0

# What to show of octocode's own output once an index run ends. octocode drives
# a progress spinner: thousands of \r-separated frames that together form ONE
# \n-terminated line, and every eprintln it emits lands glued onto whichever
# frame is current. The branches below used to `tail -N` that file, which shows
# the spinner and drops everything printed before its last line — and that is
# precisely where octocode reports LLM trouble ("Warning: AI architectural
# analysis failed", "⚠️  Batch AI description failed", "🔄 Falling back to
# individual AI calls"). Runs 32721840450 / 32746314822 shipped graphs with
# ZERO LLM relationships as green jobs this way: every batch had failed and the
# replayed log showed a healthy spinner. This drops the frames (all of them,
# they are noise), recovers any message glued onto one, strips the ANSI erase
# sequences, and prints the last $2 real lines. awk only, so the dagu/box path
# (busybox) and the GHA path (mawk/gawk) behave the same.
octo_log_digest() { # $1 = octocode log file, $2 = max lines to print
  tr '\r' '\n' < "$1" | awk -v n="$2" -v esc="$(printf '\033')" '
    { gsub(esc "\\[[0-9;]*[A-Za-z]", "") }
    /Indexing: [0-9]+(\/[0-9]+)? files|Counting files/ {
      # Spinner frames are dropped from the digest, but the LAST one is the only
      # progress signal a timed-out run leaves behind — keep it for the END line.
      if (match($0, /Indexing: [0-9]+(\/[0-9]+)? files( \([0-9]+%\))?/)) prog = substr($0, RSTART, RLENGTH)
      i = 0
      if (match($0, /(Info|Warning|Error|Debug): /)) i = RSTART
      else if (match($0, /⚠️|🔄|✓|📋|📊/)) i = RSTART
      if (!i) next
      $0 = substr($0, i)
    }
    NF { l[++k] = $0 }
    END { s = k - n + 1; if (s < 1) s = 1; for (i = s; i <= k; i++) print l[i]; if (prog) print "[cgc-db] last octocode progress: " prog }'
}

# After a graphrag-phase index, prove the LLM pass contributed. Structural extraction
# yields imports / calls / references / sibling_module / parent_module / child_module
# / contains; only the LLM prompt emits configures / factory_creates /
# observer_pattern / strategy_pattern / adapter_pattern / architectural_dependency
# (octocode src/indexer/graphrag/ai.rs — the vocabulary the prompt hands the model,
# kept as distinct RelationType variants). A graphrag checkpoint carrying none of
# them is the 2026-08-24 failure again — every LLM reply discarded, exit 0 — and
# must not be published as enriched. The text overview is asserted on purpose: it
# is the exact output the MCP surfaces hand to users.
# ponytail: repos under the node floor are exempt — a 17-node corpus can honestly
# hold no architectural pattern; switch to a description-shape check if a mid-size
# repo ever trips this falsely.
assert_llm_graph() { # $1 = repo dir, $2 = repo name → rc 1 when no LLM-derived type exists
  _alg_ov=$( cd "$1" && octocode graphrag overview --format text 2>&1 )
  _alg_nodes=$(printf '%s\n' "$_alg_ov" | awk '/contains [0-9]+ nodes and [0-9]+ relationships/ { for (i = 1; i <= NF; i++) if ($i == "contains") { print $(i + 1); exit } }')
  _alg_types=$(printf '%s\n' "$_alg_ov" | awk '/^[[:space:]]*- [a-z_]+: [0-9]+ relationship/ { t = $2; sub(/:$/, "", t); printf "%s ", t }')
  for _alg_t in $_alg_types; do
    case "$_alg_t" in
      configures|factory_creates|observer_pattern|strategy_pattern|adapter_pattern|architectural_dependency) return 0 ;;
    esac
  done
  if [ "${_alg_nodes:-0}" -lt 30 ] 2>/dev/null; then
    echo "[cgc-db] $2 · graphrag guard: ${_alg_nodes:-0} nodes (< 30) and no LLM-derived type — small corpus, accepted"
    return 0
  fi
  echo "::error::[cgc-db] $2 · graphrag phase produced NO LLM-derived relationship across ${_alg_nodes:-?} nodes (types present: ${_alg_types:-none}) — every LLM reply was discarded (empty or unparseable), the silent failure of 2026-08-24; refusing to publish a structural-only graph as a graphrag checkpoint"
  printf '%s\n' "$_alg_ov" | tail -20
  return 1
}

for r in $REPOS; do
  d="$REPOS_ROOT/$r"
  [ -d "$d" ] || { echo "::error::missing repo $d — refusing to publish an incomplete DB"; exit 1; }

  # GRAPHRAG SKIP (data-driven, .runtime.octocode.graphrag_skip — no hardcoded names
  # here). Pure prose/text corpora (e.g. cloud-data-my-ai-memory) have no code semantics to
  # relate, so the GraphRAG LLM relationship pass is real per-node LLM cost for zero
  # graph nodes. Only the graphrag phase (USE_LLM=true) skips these repos — structural/
  # FastEmbed indexing (the semantic phase, USE_LLM=false) still runs normally for them,
  # so they are fully search/embed-able, just never LLM-graphed. Checked BEFORE the time
  # budget below so a skipped repo never consumes a reserve slot or gets counted deferred.
  if [ "$USE_LLM" = "true" ]; then
    _gskip=$(jq -r --arg r "$r" '(.runtime.octocode.graphrag_skip // []) | index($r) != null' "$BJ")
    if [ "$_gskip" = "true" ]; then
      echo "[cgc-db] === graphrag skip: $r (text corpus, no code graph — .runtime.octocode.graphrag_skip) ==="
      N_SKIP=$(( N_SKIP + 1 ))
      continue
    fi
  fi

  # TIME BUDGET: stop before the runner cap so we always reach a clean push+exit.
  # RESERVE the repo's worst case (a full repo_timeout_min) BEFORE admitting it. Gating
  # only on "budget not yet spent" admits a repo at minute 299 that is then allowed to run
  # repo_timeout_min longer — so the true worst case is max_minutes + repo_timeout_min, not
  # max_minutes. That overshoots GitHub's hard job ceiling, which kills the runner mid-repo:
  # no final package/push, and the checkpoint for the in-flight repo is lost. Reserving up
  # front is what actually makes the "never killed mid-repo" invariant above true.
  # A repo_timeout_min of 0 (no per-repo timeout) reserves nothing and keeps the old gate.
  # ADAPTIVE RESERVE. A FIXED reserve deadlocks: it must be large enough for the slowest
  # repo to finish (cloud-infra-desktop needs ~200m+ at measured throughput) yet small enough that a
  # repo is still admitted late in the run — and those cannot both hold, because admission
  # requires elapsed + reserve <= max_minutes. With reserve=180 nothing is admitted after
  # 120m; raise it so the giants fit and they are never admitted at all, since the small
  # repos alone consume ~75m. Clamp instead: give each repo the SMALLER of its configured
  # ceiling and the budget actually left. Worst case is still bounded by max_minutes (the
  # clamp can never hand out more time than remains), giants get every minute available
  # rather than a fixed slice, and a repo is only skipped when too little time remains to
  # be worth starting. REPO_TIMEOUT_MIN is now a CEILING, not a reservation.
  REPO_TIMEOUT_EFF="$REPO_TIMEOUT_MIN"
  if [ -n "$BUDGET_MIN" ] && [ "$BUDGET_MIN" != "0" ]; then
    _elapsed=$(( ( $(date +%s) - START_TS ) / 60 ))
    _remain=$(( BUDGET_MIN - _elapsed ))
    _reserve="${REPO_TIMEOUT_MIN:-0}"
    [ -n "$_reserve" ] || _reserve=0
    # Clamp the ceiling to what is left; 0 means "no ceiling configured" so take the remainder.
    if [ "$_reserve" = "0" ] || [ "$_remain" -lt "$_reserve" ]; then REPO_TIMEOUT_EFF="$_remain"; fi
    # Floor: starting a repo with only a few minutes left burns a 15G checkpoint push for
    # almost no indexing. Defer instead and give it a full slice next run.
    if [ "$_remain" -lt "${CGC_MIN_SLICE_MIN:-20}" ]; then
      _n_left=0; for _q in $REPOS; do _n_left=$(( _n_left + 1 )); done
      N_DEFER=$(( _n_left - N_INDEX - N_SKIP - N_TIMEOUT ))
      echo "[cgc-db] only ${_remain}m of the ${BUDGET_MIN}m budget left (<${CGC_MIN_SLICE_MIN:-20}m floor) — deferring $r (+${N_DEFER} total) to next run"
      break
    fi
  fi

  # CHANGE GATE: HEAD unchanged since last index into this DB → nothing to do.
  # CGC_FORCE=1 bypasses it. The manifest is keyed on repo HEAD alone, but the
  # DB's freshness also depends on HOW it was indexed — when the INDEXER changes
  # (embedding model, graphrag settings, a fixed LLM endpoint), every entry is
  # stale at an unchanged HEAD and the gate would skip all of them forever. That
  # is not hypothetical: the graphrag manifest was advanced by runs that silently
  # produced structural-only graphs, so re-running after fixing the LLM wiring is
  # a no-op without this. Reindexing on a config change is the whole point.
  cur=$(git -C "$d" rev-parse HEAD 2>/dev/null || echo "")
  last=$(jq -r --arg r "$r" '.[$r] // ""' "$MANIFEST")
  if [ "${CGC_FORCE:-0}" = "1" ] && [ -n "$last" ]; then
    echo "[cgc-db] === force $r — ignoring manifest entry @ $last (CGC_FORCE=1) ==="
  elif [ -n "$cur" ] && [ "$cur" = "$last" ]; then
    echo "[cgc-db] === skip $r — unchanged @ $cur ==="
    N_SKIP=$(( N_SKIP + 1 ))
    continue
  fi

  exclude_submodules "$d"
  # Base .noindex from build.json conventions (dist/vendor/node_modules/z_archive/lockfiles).
  : > "$d/.noindex"
  if [ -n "$NOINDEX_PATTERNS" ]; then
    printf '%s\n' "$NOINDEX_PATTERNS" > "$d/.noindex"
    echo "[cgc-db] $r · .noindex base: $(printf '%s' "$NOINDEX_PATTERNS" | tr '\n' ' ')"
  fi
  # PER-REPO noindex extension (data-driven, .runtime.octocode.noindex_extra keyed by
  # local repo name — no hardcoded paths here). Layered on top of the global base above,
  # for content only ONE repo needs excluded (e.g. cloud-data-my-ai-memory's a_sessions/ and
  # a_commits/ — see build.json's _noindex_extra_comment for why).
  NOINDEX_EXTRA=$(jq -r --arg r "$r" '((.runtime.octocode.noindex_extra // {})[$r] // []) | .[]' "$BJ" 2>/dev/null)
  if [ -n "$NOINDEX_EXTRA" ]; then
    printf '%s\n' "$NOINDEX_EXTRA" >> "$d/.noindex"
    echo "[cgc-db] $r · .noindex extra: $(printf '%s' "$NOINDEX_EXTRA" | tr '\n' ' ')"
  fi
  # SMART: auto-append binary-dominated dirs (generic, no hardcoded paths).
  smart_noindex "$d"

  # Throughput + pressure, so the NEXT run diagnoses itself instead of needing a log
  # archaeology pass. 2026-08-20 measured ~5.2s/file on a structural no-LLM index, which is
  # ~100x too slow and is the real root cause behind every symptom above; the suspect is the
  # 16G DB (du -sh, cloud-cgc-db-pull.sh) restored under MemoryMax=16G + MemorySwapMax=0 on
  # a 16GB runner, i.e. page cache thrash on every vector lookup. Do NOT tune mem_max on a
  # hunch — these two lines plus the files/min below say whether it is memory or disk.
  _files=$(git -C "$d" ls-files 2>/dev/null | wc -l)
  echo "[cgc-db] $r · pressure before index: mem=$(free -g 2>/dev/null | awk '/^Mem:/{print $3"/"$2"G used, "$6"G cache"}') disk=$(df -h "$OCTO_HOME" 2>/dev/null | awk 'NR==2{print $4" free"}')"
  # STRAY-SELECT (per-repo mode only — see project_dirs_snapshot()/resolve_project_dir()
  # above): snapshot the project dirs under OCTO_HOME and stamp an mtime marker
  # RIGHT BEFORE this repo's own index, so the diff after it can tell which dir
  # this specific index run produced/touched regardless of what else is in the home.
  _before_dirs="" _idx_marker=""
  if [ "${CGC_PACKAGE_MODE:-monolith}" = "per-repo" ]; then
    _before_dirs=$(project_dirs_snapshot "$OCTO_HOME")
    _idx_marker=$(mktemp)
  fi
  _t0=$(date +%s)
  echo "[cgc-db] === incremental index: $r (was=${last:-none} now=$cur, ${_files} files) ==="
  # Capture octocode's REAL exit status (a pipe to `tail` would mask it) and make a
  # failed index FATAL — never package/push an unindexed base as a fake update.
  _log="$(mktemp)"
  _rc=0
  if [ -n "$REPO_TIMEOUT_EFF" ] && [ "$REPO_TIMEOUT_EFF" != "0" ]; then
    echo "[cgc-db] $r · slice ${REPO_TIMEOUT_EFF}m (ceiling ${REPO_TIMEOUT_MIN:-none}m, budget left ${_remain:-?}m)"
    ( cd "$d" && timeout "${REPO_TIMEOUT_EFF}m" octocode index ) >"$_log" 2>&1 || _rc=$?
  else
    ( cd "$d" && octocode index ) >"$_log" 2>&1 || _rc=$?
  fi
  _dt=$(( $(date +%s) - _t0 ))
  if [ "$_rc" = "124" ]; then
    # On timeout the denominator is unknown: dividing the slice by the FULL file count
    # (2026-09-03: "0.53s/file" for android, real rate ~670 files per 240m slice) reads
    # as a throughput number and misled the sizing. The digest below prints octocode's
    # own "Loaded metadata for N files" (files already in the DB when this run began) and
    # its last progress state; the delta between consecutive runs is the real rate.
    echo "[cgc-db] $r · index took ${_dt}s of ${_files} files (TIMEOUT — partial, s/file not meaningful, rc=124)"
  else
    echo "[cgc-db] $r · index took ${_dt}s for ${_files} files ($(awk -v d="$_dt" -v f="$_files" 'BEGIN{printf (f>0? "%.2f":"n/a"), d/(f>0?f:1)}')s/file, rc=$_rc)"
  fi
  # STRAY-SELECT resolution — only for runs that actually reached/touched a project
  # dir (rc=0 success or rc=124 partial, both checkpoint below); a hard failure
  # (the else branch) exits before ever reaching checkpoint_publish, so it needs no
  # resolved dir. Ambiguity is fatal here, same severity as an index failure: we
  # refuse to package/push a checkpoint we cannot positively identify.
  _proj_resolved=""
  if [ "${CGC_PACKAGE_MODE:-monolith}" = "per-repo" ] && { [ "$_rc" = "0" ] || [ "$_rc" = "124" ]; }; then
    _proj_resolved=$(resolve_project_dir "$OCTO_HOME" "$_before_dirs" "$_idx_marker") \
      || { rm -f "$_idx_marker" "$_log" 2>/dev/null; echo "::error::[cgc-db] $r · cannot identify which project dir this index produced — refusing to package/push an unidentifiable checkpoint"; exit 1; }
    echo "[cgc-db] $r · resolved project dir: $_proj_resolved"
  fi
  rm -f "$_idx_marker" 2>/dev/null || true
  if [ "$_rc" = "0" ]; then
    octo_log_digest "$_log" 40; rm -f "$_log"
    # graphrag phase only: no LLM-derived edges = no checkpoint (see assert_llm_graph).
    if [ "$USE_LLM" = "true" ]; then assert_llm_graph "$d" "$r" || exit 1; fi
  elif [ "$_rc" = "124" ]; then
    echo "[cgc-db] WARN $r timed out after ${REPO_TIMEOUT_EFF}m slice — publishing PARTIAL progress, will resume next run"
    octo_log_digest "$_log" 40; rm -f "$_log"
    N_TIMEOUT=$(( N_TIMEOUT + 1 ))
    # PUBLISH the partial index, but do NOT advance the manifest. Those two are separate
    # decisions and conflating them is what made the outage permanent: on timeout the
    # embeddings octocode already wrote ARE in the DB, yet the old code discarded them by
    # returning without a push, so every run redid and rediscarded the same 55% of
    # cloud-infra forever — a repo too big for one timeout could never finish, ever.
    # Pushing without advancing the manifest is the safe half of the pair: the repo stays
    # "not indexed" and retries next run, but the work it did survives in the base DB, so
    # successive runs ratchet forward instead of resetting. Worst case if octocode does not
    # skip already-embedded files, this costs one extra push and converges no slower than
    # before; it cannot mark a repo done that is not done, because the manifest is untouched.
    echo "[cgc-db] checkpoint publish after $r (PARTIAL — manifest not advanced)"
    checkpoint_publish "$r"
    PUSHED=1
    continue
  else
    echo "::error::octocode index FAILED for $r (rc=$_rc) — aborting BEFORE package/push so no no-op DB is published:"
    octo_log_digest "$_log" 60; rm -f "$_log"; exit 1
  fi

  # Record the indexed commit in the DB home (travels via package/pull), THEN
  # checkpoint-push so this repo's progress is durable before we touch the next.
  _tmp=$(mktemp); jq --arg r "$r" --arg c "$cur" '.[$r]=$c' "$MANIFEST" > "$_tmp" && mv "$_tmp" "$MANIFEST"
  echo "[cgc-db] checkpoint publish after $r"
  checkpoint_publish "$r"
  # FIX 2 — see seed_base_if_missing() above. Only after a genuinely SUCCESSFUL
  # index + checkpoint (not the PARTIAL/timeout branch above): the home now holds
  # a complete config.toml + whatever model caches this index run touched.
  [ "${CGC_PACKAGE_MODE:-monolith}" = "per-repo" ] && seed_base_if_missing
  PUSHED=1
  N_INDEX=$(( N_INDEX + 1 ))
done

echo "[cgc-db] SUMMARY phase=${MANIFEST_PHASE:-default}: ${N_INDEX} indexed, ${N_SKIP} unchanged, ${N_TIMEOUT} timed out, ${N_DEFER} deferred"

# 5/6) Propagate to the deployed consumer (oci-apps) so it serves the new DB now.
#      Only when something actually changed this cycle (checkpoints already pushed
#      it to GHCR). CGC_SKIP_PROPAGATE=1 lets a caller defer propagation.
#      CGC_PACKAGE_MODE=per-repo ALWAYS skips this rsync-whole-home path, even if a
#      caller forgot CGC_SKIP_PROPAGATE=1: OCTO_HOME here is a fresh home that has, at
#      most, the shared base state plus ONE repo's project dir — rsync --delete'ing
#      that over the live volume (which holds every OTHER repo's data too) would
#      DESTROY the rest. The matrix workflow's own restore-all job (base + every
#      per-repo image, assembled together) propagates instead.
if [ "${CGC_PACKAGE_MODE:-monolith}" = "per-repo" ]; then
  echo "[cgc-db] per-repo mode — propagate_to_host (rsync whole home) is never used here; the matrix workflow's restore-all job propagates instead"
elif [ "$PUSHED" = "0" ] && [ "$N_TIMEOUT" = "0" ] && [ "$N_DEFER" = "0" ]; then
  echo "[cgc-db] no repo changed — DB already current, nothing to publish or propagate"
elif [ "$PUSHED" = "0" ]; then
  # NOT the same as "already current" — this is an incomplete cycle. Say so loudly enough
  # that a scheduled run reads as the outage it is, instead of six days of quiet green.
  echo "::warning::[cgc-db] nothing published: ${N_TIMEOUT} repo(s) timed out, ${N_DEFER} deferred — DB is STALE, not current"
elif [ "${CGC_SKIP_PROPAGATE:-}" = "1" ]; then
  echo "[cgc-db] propagation deferred (CGC_SKIP_PROPAGATE=1)"
else
  propagate_to_host
fi

if [ "${CGC_PACKAGE_MODE:-monolith}" = "per-repo" ]; then
  echo "[cgc-db] UPDATE COMPLETE → ${REPO_PREFIX:-}<repo>:${REPO_TAG:-latest} (per-repo)"
else
  echo "[cgc-db] UPDATE COMPLETE → $IMAGE:$TAG"
fi
