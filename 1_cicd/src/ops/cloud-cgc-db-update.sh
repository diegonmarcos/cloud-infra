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
OCTO_X86=$(jq -r '.runtime.octocode.octocode_images.x86' "$BJ")
OCTO_ARM=$(jq -r '.runtime.octocode.octocode_images.arm' "$BJ")
# Data-driven exclude globs. octocode honours a gitignore-syntax `.noindex` file
# (in addition to `.gitignore`). dist/, vendor/, z_archive/ are git-COMMITTED here
# so `.gitignore` misses them — without this octocode embeds ~73% generated/vendored/
# archived junk, bloating the graph and tripling every index. One `.noindex` per repo.
NOINDEX_PATTERNS=$(jq -r '.runtime.octocode.noindex_patterns // [] | .[]' "$BJ" 2>/dev/null)
# Arch-aware binary: ARM runner (oci-apps aarch64) uses the arm image; x86 GHA uses x86.
case "$(uname -m)" in
  aarch64|arm64) OCTO_IMAGE="$OCTO_ARM" ;;
  *)             OCTO_IMAGE="$OCTO_X86" ;;
esac
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

# 0b) ensure a FastEmbed-CAPABLE octocode on PATH. A binary built WITHOUT FastEmbed
#     (e.g. some nix/static builds — oci-apps' nix-profile octocode is one) fails
#     `octocode index` at runtime; the producer would then package the UNCHANGED
#     base = a silent no-op "update". So we VERIFY capability and, if the on-PATH
#     octocode lacks it, extract the pinned image binary (the *-fastembed-* images
#     are built with it). Pinned version keeps the DB schema compatible.
# AUDITED (STRAY-PREVENT): this IS an `octocode index` call, but it already runs cd'd
# into its own fresh mktemp -d ($_t, unique per call) — never the ambient cwd
# / cloud-infra checkout — so it cannot be the stable-per-job stray described
# above. It DOES `git init` that dir first: octocode's config default is
# require_git=true (see bootstrap_config_toml() below), so an ungit'd dir
# risks failing on "not a git repository" before ever reaching the FastEmbed
# capability check this probe exists to observe — leave it as is. $_t has no
# origin remote, so even if it stamps a project entry, that entry's key is not
# derived from a stable origin URL the way cloud-infra's is; harmless
# left-over strays from this call (if any) are still handled generically by
# STRAY-SELECT's before/after diff in the per-repo loop, which excludes anything
# already present before the target repo's own index runs.
octocode_has_fastembed() {  # $1 = octocode binary path/name
  _t="$(mktemp -d)"; ( cd "$_t" && git init -q . >/dev/null 2>&1 ) || true
  _o="$( ( cd "$_t" && "$1" index ) 2>&1 || true )"; rm -rf "$_t"
  case "$_o" in *"FastEmbed support is not compiled in"*) return 1 ;; *) return 0 ;; esac
}
ensure_octocode() {
  if command -v octocode >/dev/null 2>&1 && octocode_has_fastembed octocode; then
    echo "[cgc-db] octocode: $(cd "$CGC_SCRATCH" && octocode --version 2>/dev/null) (FastEmbed ok)"; return 0
  fi
  command -v docker >/dev/null 2>&1 || { echo "::error::need a FastEmbed-capable octocode or docker to obtain it"; exit 1; }
  bindir="${CGC_BIN:-$HOME/.local/bin}"; mkdir -p "$bindir"
  echo "[cgc-db] on-PATH octocode missing/no-FastEmbed — extracting pinned $OCTO_IMAGE (arch: $(uname -m))"
  docker pull -q "$OCTO_IMAGE" >/dev/null
  docker run --rm --entrypoint sh "$OCTO_IMAGE" -c 'cat "$(command -v octocode)"' > "$bindir/octocode"
  chmod +x "$bindir/octocode"
  # The arm image's octocode is DYNAMICALLY linked (unlike the x86 -static build):
  # it needs libssl.so.3 + libcrypto.so.3 at runtime. A host usually has them, but a
  # minimal runner (the gha-runner container) does NOT → "libssl.so.3: cannot open
  # shared object file" (rc 127). Stream the libs from the SAME image (stdout, not a
  # -v mount — under the docker-socket sibling setup a mount resolves to the HOST
  # path) and point LD_LIBRARY_PATH at them → self-contained, runs anywhere.
  for _l in libssl.so.3 libcrypto.so.3; do
    docker run --rm --entrypoint sh "$OCTO_IMAGE" \
      -c "_s=\$(find / -name '$_l' 2>/dev/null | head -1); [ -n \"\$_s\" ] && cat \"\$_s\"" \
      > "$bindir/$_l" 2>/dev/null || true
    [ -s "$bindir/$_l" ] || rm -f "$bindir/$_l"
  done
  PATH="$bindir:$PATH"; export PATH
  LD_LIBRARY_PATH="$bindir:${LD_LIBRARY_PATH:-}"; export LD_LIBRARY_PATH
  octocode_has_fastembed "$bindir/octocode" || { echo "::error::pinned image octocode ALSO lacks FastEmbed: $OCTO_IMAGE"; exit 1; }
  echo "[cgc-db] octocode: $(cd "$CGC_SCRATCH" && octocode --version 2>/dev/null) (FastEmbed ok, from image)"
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
      # resolves) and omits only historical file contents, fetching blobs on demand for the
      # checkout it actually walks. Runner disk is the binding constraint here — the DB
      # alone restores to 16G on a ~14G runner — so not downloading every blob of every
      # past commit for seven repos is free headroom. Falls back to a full clone if the
      # remote refuses partial clone, so this can never be the thing that fails a run.
      git clone -q --filter=blob:none "$url" "$d" 2>/dev/null \
        || git clone -q "$url" "$d" 2>/dev/null \
        || { echo "::error::[cgc-db] clone $lname ← $remote failed (private repo without a CGC_DEPLOY_KEY_* secret?)"; : > "$_clonefail"; }
      # Same reason as the refresh path: strip any credential back out of origin so
      # the project_id octocode derives is the canonical, consumer-matching one.
      git -C "$d" remote set-url origin "$canon" 2>/dev/null || true
    fi
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

# BOOTSTRAP config.toml (per-repo mode only). Production incident 2026-08-21 (run
# 32502667627, all 7 matrix jobs, identical): before cgc-db-base:latest ever exists
# on GHCR (the very first cycle), the base/self restore above is a no-op —
# cloud-cgc-db-pull.sh warns-and-continues on a missing image (see its own header)
# — so OCTO_HOME has NO config.toml at this point. octocode 0.12.2 (verified
# against the exact pinned binary: a bare `octocode config` with no flags prints
# usage and creates NOTHING, but `octocode index`/`octocode config --show` in a
# config-less home silently AUTO-GENERATE one using octocode's OWN compiled-in
# embedding defaults — voyage:voyage-code-3 / voyage:voyage-3.5-lite, CLOUD models
# needing VOYAGE_API_KEY) — so `octocode index` then dies at the very first
# embedding call with "VOYAGE_API_KEY environment variable not set", before a
# single file is indexed. The OLD fallback here (`octocode config`, no flags) was
# a silent no-op, which is why this was never caught: it looks like it handles
# the missing-file case but does not.
#
# Our models are LOCAL fastembed — build.json .runtime.octocode.update.
# code_embedding_model / text_embedding_model, already parsed into $CODE_EMBED /
# $TEXT_EMBED above — ONE source of truth; a wrong/missing model here silently
# drop_tables data on a later restore (see cloud-cgc-db-package.sh's base-image
# DESC). We do NOT shell out to `octocode config --code-embedding-model ...` to
# generate this file, even though that CLI flow does exist and IS used below
# (4a/4b) against a config.toml that already exists: that command writes to
# octocode's OWN resolved home directory (derived from $HOME, NOT from
# $OCTOCODE_HOME/$OCTO_HOME — verified against the pinned 0.12.2 binary, which has
# no env var or CLI flag to relocate its data dir at all), so it cannot be trusted
# to land the file at $CFG. Writing the file directly guarantees it lands exactly
# where the rest of this script (and every later restore) expects it. Schema below
# is octocode 0.12.2's OWN generated default (verified byte-for-byte against a
# fresh `octocode config --show` in an empty home on the pinned version) with only
# the two [embedding] lines swapped for build.json's models — every other default
# is left exactly as octocode itself would generate it.
bootstrap_config_toml() {
  [ -f "$CFG" ] && return 0
  mkdir -p "$(dirname "$CFG")"
  cat > "$CFG" <<CFGEOF
version = 1

[llm]
model = "$LLM"
timeout = 120
temperature = 0.7
max_tokens = 4000

[index]
chunk_size = 2000
chunk_overlap = 100
embeddings_batch_size = 16
embeddings_max_tokens_per_batch = 100000
flush_frequency = 2
require_git = true

[search]
max_results = 20
similarity_threshold = 0.65
output_format = "markdown"
max_files = 10
context_lines = 3
search_block_max_characters = 400

[search.reranker]
enabled = false
model = "voyage:rerank-2.5"
top_k_candidates = 50
final_top_k = 10

[search.hybrid]
enabled = false
default_vector_weight = 0.7
default_keyword_weight = 0.3
keyword_path_weight = 2.0
keyword_content_weight = 1.0
keyword_symbols_weight = 2.5
keyword_title_weight = 3.0

[embedding]
code_model = "$CODE_EMBED"
text_model = "$TEXT_EMBED"

[graphrag]
enabled = false
use_llm = false

[graphrag.llm]
description_model = "$LLM"
relationship_model = "$LLM"
ai_batch_size = 8
max_batch_tokens = 16384
batch_timeout_seconds = 60
fallback_to_individual = true
max_sample_tokens = 1500
confidence_threshold = 0.6
architectural_weight = 0.9
relationship_system_prompt = """
You are an expert software architect specializing in code analysis. Analyze the provided code files and identify meaningful ARCHITECTURAL relationships that go beyond simple imports.

Focus on these relationship types:
- 'imports': Module/package imports and dependencies
- 'implements': Interface implementation, trait implementation
- 'extends': Class inheritance, module extension
- 'calls': Function/method calls between modules
- 'uses': Utility usage, service consumption
- 'configures': Configuration setup, dependency injection
- 'factory_creates': Factory pattern instantiation
- 'observer_pattern': Event listening, callback registration
- 'strategy_pattern': Algorithm selection, behavior delegation
- 'adapter_pattern': Interface adaptation, wrapper usage
- 'architectural_dependency': High-level system dependencies

Respond with a JSON array of relationships. Each relationship must include:
- source_path: relative path of source file
- target_path: relative path of target file
- relation_type: one of the types listed above
- description: specific explanation of HOW the relationship works
- confidence: 0.0-1.0 confidence score (use 0.8+ for clear relationships)

Only include relationships with clear architectural significance. Avoid trivial imports."""
description_system_prompt = """
You are a senior software engineer analyzing code architecture. Provide a concise 2-3 sentence description of the file's ROLE and PURPOSE in the system.

Focus on:
- What architectural layer this file belongs to (API, business logic, data access, utilities, etc.)
- Its primary responsibility and how it contributes to the system
- Key patterns or architectural decisions it implements

Avoid listing specific functions/classes. Instead, describe the file's architectural significance and how it fits into the larger system design."""
CFGEOF
  echo "[cgc-db] bootstrap: wrote config.toml (models: code=$CODE_EMBED text=$TEXT_EMBED)"
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
# GHCR auth FIRST — ensure_octocode pulls the (private) pinned octocode image, so
# docker must be logged in before it runs. On a host with cached creds this order
# was masked; a fresh runner container has none → "denied" on the image manifest.
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
    if [ "${CGC_FORCE:-0}" = "1" ] && [ "$USE_LLM" = "true" ]; then
      echo "[cgc-db] CGC_FORCE + LLM — skipping prior checkpoint of $_r: full re-index from base"
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

for r in $REPOS; do
  d="$REPOS_ROOT/$r"
  [ -d "$d" ] || { echo "::error::missing repo $d — refusing to publish an incomplete DB"; exit 1; }

  # GRAPHRAG SKIP (data-driven, .runtime.octocode.graphrag_skip — no hardcoded names
  # here). Pure prose/text corpora (e.g. cloud-my-ai_memory) have no code semantics to
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
  # repo to finish (cloud-unix needs ~200m+ at measured throughput) yet small enough that a
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
  # for content only ONE repo needs excluded (e.g. cloud-my-ai_memory's a_sessions/ and
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
  # s/file is exact on success and a lower bound on timeout (denominator is the full file
  # count, but only part of it got indexed) — either way it is the number to watch.
  _dt=$(( $(date +%s) - _t0 ))
  echo "[cgc-db] $r · index took ${_dt}s for ${_files} files ($(awk -v d="$_dt" -v f="$_files" 'BEGIN{printf (f>0? "%.2f":"n/a"), d/(f>0?f:1)}')s/file, rc=$_rc)"
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
    tail -4 "$_log"; rm -f "$_log"
  elif [ "$_rc" = "124" ]; then
    echo "[cgc-db] WARN $r timed out after ${REPO_TIMEOUT_EFF}m slice — publishing PARTIAL progress, will resume next run"
    tail -10 "$_log"; rm -f "$_log"
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
    tail -30 "$_log"; rm -f "$_log"; exit 1
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
