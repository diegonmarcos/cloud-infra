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
# USE_LLM selects the GraphRAG LLM phase. Two-phase orchestration (cgc-db.yml →
# cgc-db-index.yml) drives this via the environment: the `semantic` phase exports
# USE_LLM=false, the `graphrag` phase exports USE_LLM=true. The ENVIRONMENT is
# authoritative; build.json runtime.octocode.update.use_llm is only the fallback
# default when the caller does not set USE_LLM (e.g. a bare local invocation).
USE_LLM="${USE_LLM:-$(jq -r '.runtime.octocode.update.use_llm' "$BJ")}"
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

# 0b) ensure a FastEmbed-CAPABLE octocode on PATH. A binary built WITHOUT FastEmbed
#     (e.g. some nix/static builds — oci-apps' nix-profile octocode is one) fails
#     `octocode index` at runtime; the producer would then package the UNCHANGED
#     base = a silent no-op "update". So we VERIFY capability and, if the on-PATH
#     octocode lacks it, extract the pinned image binary (the *-fastembed-* images
#     are built with it). Pinned version keeps the DB schema compatible.
octocode_has_fastembed() {  # $1 = octocode binary path/name
  _t="$(mktemp -d)"; ( cd "$_t" && git init -q . >/dev/null 2>&1 ) || true
  _o="$( ( cd "$_t" && "$1" index ) 2>&1 || true )"; rm -rf "$_t"
  case "$_o" in *"FastEmbed support is not compiled in"*) return 1 ;; *) return 0 ;; esac
}
ensure_octocode() {
  if command -v octocode >/dev/null 2>&1 && octocode_has_fastembed octocode; then
    echo "[cgc-db] octocode: $(octocode --version 2>/dev/null) (FastEmbed ok)"; return 0
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
  echo "[cgc-db] octocode: $(octocode --version 2>/dev/null) (FastEmbed ok, from image)"
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
mkdir -p "$OCTO_HOME"
sh "$HERE/cloud-cgc-db-pull.sh" "$OCTO_HOME" || true
if [ -z "$(ls -A "$OCTO_HOME" 2>/dev/null | grep -v '^config\.toml$')" ]; then
  echo "::error::no GHCR DB base restored — refusing a from-scratch full build (~12h)."
  echo "::error::seed once first: sh $HERE/cloud-cgc-db-package.sh <existing-octocode-home> $IMAGE $TAG"
  exit 1
fi
[ -f "$CFG" ] || octocode config >/dev/null 2>&1 || true

# 4a) force the GraphRAG LLM phase on (use_llm + model). awk, never sed.
if [ "$USE_LLM" = "true" ] && [ -f "$CFG" ]; then
  octocode config --model "$LLM" --graphrag-enabled true >/dev/null 2>&1 || true
  awk -v m="$LLM" '
    /^\[graphrag\]/                                { in_gr=1 }
    /^\[/ && !/^\[graphrag\]/                      { in_gr=0 }
    in_gr && /^[[:space:]]*enabled[[:space:]]*=/   { print "enabled = true"; next }
    /^[[:space:]]*use_llm[[:space:]]*=/            { print "use_llm = true"; next }
    /^[[:space:]]*description_model[[:space:]]*=/  { print "description_model = \"" m "\""; next }
    /^[[:space:]]*relationship_model[[:space:]]*=/ { print "relationship_model = \"" m "\""; next }
    { print }' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
  grep -q "use_llm = true" "$CFG" 2>/dev/null || printf '\n[graphrag]\nenabled = true\nuse_llm = true\n' >> "$CFG"
  echo "[cgc-db] GraphRAG LLM = $LLM (enabled=true use_llm=true)"
else
  # Force structural-only to MATCH build.json (use_llm=false). The base config.toml
  # may carry a STALE `use_llm = true` + an unreachable LLM model (e.g. ollama:*),
  # which makes octocode block on per-batch LLM timeouts → glacial. Previously this
  # branch only PRINTED "structural-only" without disabling it. Disable it for real.
  if [ -f "$CFG" ]; then
    octocode config --graphrag-enabled false --code-embedding-model "$CODE_EMBED" --text-embedding-model "$TEXT_EMBED" >/dev/null 2>&1 || true
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
# Outcome tally. "no repo changed — DB already current" was printed on 2026-08-20 after two
# repos had TIMED OUT and five were deferred: a green log during a six-day outage. Count
# every terminal state per repo so the summary can never claim currency it has not earned.
N_INDEX=0; N_SKIP=0; N_TIMEOUT=0; N_DEFER=0

for r in $REPOS; do
  d="$REPOS_ROOT/$r"
  [ -d "$d" ] || { echo "::error::missing repo $d — refusing to publish an incomplete DB"; exit 1; }

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
  cur=$(git -C "$d" rev-parse HEAD 2>/dev/null || echo "")
  last=$(jq -r --arg r "$r" '.[$r] // ""' "$MANIFEST")
  if [ -n "$cur" ] && [ "$cur" = "$last" ]; then
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
    CGC_BUILD_JSON="$BJ" sh "$HERE/cloud-cgc-db-package.sh" "$OCTO_HOME" "$IMAGE" "$TAG"
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
  CGC_BUILD_JSON="$BJ" sh "$HERE/cloud-cgc-db-package.sh" "$OCTO_HOME" "$IMAGE" "$TAG"
  PUSHED=1
  N_INDEX=$(( N_INDEX + 1 ))
done

echo "[cgc-db] SUMMARY phase=${MANIFEST_PHASE:-default}: ${N_INDEX} indexed, ${N_SKIP} unchanged, ${N_TIMEOUT} timed out, ${N_DEFER} deferred"

# 5/6) Propagate to the deployed consumer (oci-apps) so it serves the new DB now.
#      Only when something actually changed this cycle (checkpoints already pushed
#      it to GHCR). CGC_SKIP_PROPAGATE=1 lets a caller defer propagation.
if [ "$PUSHED" = "0" ] && [ "$N_TIMEOUT" = "0" ] && [ "$N_DEFER" = "0" ]; then
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

echo "[cgc-db] UPDATE COMPLETE → $IMAGE:$TAG"
