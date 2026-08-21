#!/bin/sh
# ──────────────────────────────────────────────────────────────────────────
#  cloud-cgc-db-package.sh — package an octocode home → GHCR image + push
# ──────────────────────────────────────────────────────────────────────────
#  Packaging path used by cloud-cgc-db-update.sh (producer: local octocode home
#  → GHCR). GHCR is the single upstream for the cloud-cgc octocode DB (semantic
#  FastEmbed vectors + GraphRAG graph). Consumers pull it back with
#  cloud-cgc-db-pull.sh (local) / cloud-cgc-db-restore.sh (oci-apps).
#
#  THREE packaging MODES, auto-detected from the image name (no new arg, no
#  env required — ${IMAGE##*/} already carries everything needed):
#    · monolith — IMAGE does NOT match "cgc-db-*". The ORIGINAL whole-octocode-
#      home path: tar the ENTIRE $SRC, push, whole-DB visibility check against
#      every repo in .runtime.octocode.index_repos. UNCHANGED — kept working
#      until the matrix that replaces the serial loop is proven green.
#    · base    — IMAGE ends "cgc-db-base". Packages ONLY the octocode home ROOT
#      state (config.toml, fastembed/, sentencetransformer/ model caches) —
#      NO project dirs. This is what a consumer restores FIRST, once, before
#      layering per-repo images on top; embedding models must stay pinned
#      identical everywhere or a mismatch silently drop_tables a repo.
#    · repo    — IMAGE ends "cgc-db-<local_name>" for any other local_name.
#      $SRC is a FRESH octocode home that just indexed ONE repo (a matrix job),
#      so the single <project_id>/ directory it contains IS the one to package
#      — no hash computation, correct by construction. Excludes
#      <project_id>/index.lock (a baked-in live PID sends the consumer's
#      octocode into an indefinite retry loop) and <project_id>/logs/ +
#      latest_log.txt. Visibility MATCHES the repo (resolved via
#      .runtime.octocode.repo_map + `gh repo view --json isPrivate`), replacing
#      the whole-DB deny-list check for this image.
#  CGC_PKG_MODE=monolith|base|repo overrides auto-detection (escape hatch for
#  testing/edge cases; unset in every real caller).
#
#  Args: $1=SRC_DIR (octocode home)  $2=IMAGE (ghcr.io/...)  $3=TAG
#
#  Sourced with CGC_PKG_SOURCE_ONLY=1, this file defines every function below
#  and calls NONE of them — a test harness can then invoke find_project_dir /
#  build_base_tar / build_repo_tar / visibility_* directly against the real
#  logic (stubbing gh/jq as needed) instead of maintaining a parallel copy.
# ──────────────────────────────────────────────────────────────────────────
set -eu

# ── shared helpers ──────────────────────────────────────────────────────────

# Locate build.json: CGC_BUILD_JSON env wins; else derive from THIS script's
# location. $0 is only meaningful for a direct `sh cloud-cgc-db-package.sh`
# invocation — callers that need it while sourced (tests) set CGC_BUILD_JSON.
resolve_bj() {
  if [ -n "${CGC_BUILD_JSON:-}" ] && [ -f "$CGC_BUILD_JSON" ]; then
    printf '%s\n' "$CGC_BUILD_JSON"
    return 0
  fi
  _rbj_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." 2>/dev/null && pwd || echo "")
  if [ -n "$_rbj_root" ] && [ -f "$_rbj_root/a_solutions/user-ai_cloud-cgc-mcp/build.json" ]; then
    printf '%s\n' "$_rbj_root/a_solutions/user-ai_cloud-cgc-mcp/build.json"
    return 0
  fi
  return 1
}

# SINGLE-PROJECT-DIR DETECTION (repo mode). A fresh-per-job octocode home
# (ARCHITECTURE: one matrix job indexes ONE repo into a FRESH home) contains
# exactly one <project_id>/ directory once fastembed/ + sentencetransformer/
# (root-state model caches, never project data) are excluded. 0 dirs is a
# broken/empty home; 2+ means the "fresh home" invariant was violated
# (job isolation bug) — both are hard errors, named so the caller can act.
find_project_dir() { # $1=SRC → stdout: project dir name; rc!=0 on 0-or-2+
  _fpd_src="$1"
  _fpd_dirs="" _fpd_n=0
  for _fpd_e in "$_fpd_src"/*; do
    [ -d "$_fpd_e" ] || continue
    _fpd_b="${_fpd_e##*/}"
    case "$_fpd_b" in
      fastembed|sentencetransformer) continue ;;
    esac
    _fpd_dirs="$_fpd_dirs $_fpd_b"
    _fpd_n=$((_fpd_n + 1))
  done
  if [ "$_fpd_n" -eq 0 ]; then
    echo "::error::[cgc-db] no project directory found under $_fpd_src (expected exactly one <project_id>/ dir — was this repo actually indexed into a fresh octocode home?)" >&2
    return 1
  fi
  if [ "$_fpd_n" -gt 1 ]; then
    echo "::error::[cgc-db] expected exactly ONE project directory under $_fpd_src, found $_fpd_n:$_fpd_dirs (a fresh-per-job octocode home should never accumulate more than one — check matrix job isolation)" >&2
    return 1
  fi
  printf '%s\n' "${_fpd_dirs# }"
}

# BASE tar: explicit allowlist of root-state entries only. Robust even if $SRC
# also happens to hold project dirs (an allowlist can never leak one) — unlike
# a denylist, which would need to know every project id in advance.
build_base_tar() { # $1=SRC $2=TARFILE
  _bbt_src="$1"; _bbt_tar="$2"
  _bbt_paths=""
  for _bbt_p in config.toml fastembed sentencetransformer; do
    [ -e "$_bbt_src/$_bbt_p" ] && _bbt_paths="$_bbt_paths $_bbt_p"
  done
  if [ -z "$_bbt_paths" ]; then
    echo "::error::[cgc-db] no root-state entries (config.toml, fastembed/, sentencetransformer/) found under $_bbt_src" >&2
    return 1
  fi
  # shellcheck disable=SC2086
  tar cf "$_bbt_tar" -C "$_bbt_src" $_bbt_paths
}

# REPO tar: the one project dir, minus the live-PID lockfile and log noise.
build_repo_tar() { # $1=SRC $2=TARFILE $3=PROJECT_DIR_NAME
  _brt_src="$1"; _brt_tar="$2"; _brt_proj="$3"
  tar cf "$_brt_tar" -C "$_brt_src" \
    --exclude="$_brt_proj/index.lock" \
    --exclude="$_brt_proj/logs" \
    --exclude="$_brt_proj/latest_log.txt" \
    "$_brt_proj"
}

# VISIBILITY — repo mode. Resolve the repo's REMOTE name via repo_map, ask
# GitHub whether it is private, and make the package MATCH: private⇒private is
# corrected loudly (::error::, a drift here means private source is exposed);
# public⇒public just restores pull convenience. Fail-safe in every direction
# that leaves the desired visibility undetermined: unmapped local_name, an
# unreadable build.json, or a `gh repo view` failure all resolve to private.
visibility_repo() { # $1=PKG $2=LOCAL_NAME
  _vr_pkg="$1"; _vr_local="$2"
  _vr_bj=$(resolve_bj) || _vr_bj=""
  _vr_remote=""
  if [ -n "$_vr_bj" ]; then
    _vr_remote=$(jq -r --arg l "$_vr_local" '.runtime.octocode.repo_map[$l] // empty' "$_vr_bj" 2>/dev/null)
  fi
  if [ -z "$_vr_remote" ]; then
    _vr_desired=private
    echo "::error::[cgc-db] $_vr_pkg: local_name '$_vr_local' not found in repo_map (or build.json unreadable) — fail-safe: treating as private"
  else
    _vr_ispriv=$(gh repo view "diegonmarcos/$_vr_remote" --json isPrivate --jq .isPrivate 2>/dev/null || echo "")
    case "$_vr_ispriv" in
      true)  _vr_desired=private ;;
      false) _vr_desired=public ;;
      *)
        _vr_desired=private
        echo "::error::[cgc-db] $_vr_pkg: could not determine visibility of diegonmarcos/$_vr_remote — fail-safe: treating as private"
        ;;
    esac
  fi
  _vr_vis=$(gh api "/user/packages/container/${_vr_pkg}" --jq '.visibility' 2>/dev/null || echo unknown)
  if [ "$_vr_vis" = "$_vr_desired" ]; then
    echo "[cgc-db] $_vr_pkg visibility=$_vr_vis (correct — repo diegonmarcos/${_vr_remote:-?} desired=$_vr_desired)"
    return 0
  fi
  if [ "$_vr_desired" = "private" ]; then
    echo "::error::[cgc-db] $_vr_pkg is $_vr_vis but must be private (repo diegonmarcos/${_vr_remote:-unresolved} is private or undetermined) — forcing private"
  else
    echo "[cgc-db] $_vr_pkg visibility=$_vr_vis — correcting to public (repo diegonmarcos/$_vr_remote is public, restoring pull convenience)"
  fi
  gh api --method PUT "/user/packages/container/${_vr_pkg}/visibility" -f visibility="$_vr_desired" >/dev/null 2>&1 \
    && echo "[cgc-db] $_vr_pkg → $_vr_desired (corrected)" \
    || echo "::error::[cgc-db] could NOT set $_vr_pkg to $_vr_desired — fix in the GitHub UI now"
}

# VISIBILITY — base mode. No associated repo, and none is needed: the base
# image carries model caches + config only (ARCHITECTURE), never project
# content, so there is nothing to leak. Always public, for pull convenience —
# failing to flip it is only an inconvenience (private stays pullable to
# anyone already docker-logged-in), so this is a warning, never ::error::.
visibility_base() { # $1=PKG
  _vb_pkg="$1"
  _vb_vis=$(gh api "/user/packages/container/${_vb_pkg}" --jq '.visibility' 2>/dev/null || echo unknown)
  if [ "$_vb_vis" = "public" ]; then
    echo "[cgc-db] $_vb_pkg visibility=public (correct — base image carries no project content)"
    return 0
  fi
  echo "[cgc-db] $_vb_pkg visibility=$_vb_vis — setting public (base image: model caches + config only, safe to share)"
  gh api --method PUT "/user/packages/container/${_vb_pkg}/visibility" -f visibility=public >/dev/null 2>&1 \
    && echo "[cgc-db] $_vb_pkg → public (corrected)" \
    || echo "::warning::[cgc-db] could not set $_vb_pkg public — leaving as $_vb_vis"
}

# MODE auto-detection from the image name (see file header table). A pure
# function so a test harness can drive it directly with fixture image names
# instead of running the whole build+push flow.
detect_mode() { # $1=PKG → stdout: "monolith" | "base" | "repo:<local_name>"
  case "$1" in
    cgc-db-base) echo base ;;
    cgc-db-*)    echo "repo:${1#cgc-db-}" ;;
    *)           echo monolith ;;
  esac
}

# VISIBILITY — monolith mode (UNCHANGED behaviour, moved into a function).
#
# The octocode DB is a searchable index of the FULL CONTENT of every repo in
# .runtime.octocode.index_repos, and that list includes cloud-data, which is a
# PRIVATE repo (it needs CGC_DEPLOY_KEY_cloud_data to clone at all). Publishing
# this image therefore publishes private source, embedded and reconstructible,
# to anyone who can docker pull.
#
# Enforce the invariant instead of hoping: if any index_repo is private, the
# package must be private, and a public one is corrected here rather than
# merely reported. Consumers pull with credentials (oci-apps and the runner
# both already docker login to GHCR), so private costs nothing operationally.
visibility_monolith() { # $1=PKG
  _vm_pkg="$1"
  _vm_bj=$(resolve_bj) || _vm_bj=""
  _vm_priv=""
  if [ -n "$_vm_bj" ]; then
    for _vm_r in $(jq -r '.runtime.octocode.repo_map | to_entries[] | .value' "$_vm_bj" 2>/dev/null); do
      if [ "$(gh repo view "diegonmarcos/$_vm_r" --json isPrivate --jq .isPrivate 2>/dev/null)" = "true" ]; then
        _vm_priv="$_vm_priv $_vm_r"
      fi
    done
  else
    _vm_priv=" (build.json unreadable — assuming private)"
  fi
  _vm_vis=$(gh api "/user/packages/container/${_vm_pkg}" --jq '.visibility' 2>/dev/null || echo unknown)
  if [ -n "$_vm_priv" ]; then
    if [ "$_vm_vis" = "public" ]; then
      echo "::error::[cgc-db] $_vm_pkg is PUBLIC but indexes private repo(s):$_vm_priv — forcing private"
      gh api --method PUT "/user/packages/container/${_vm_pkg}/visibility" -f visibility=private >/dev/null 2>&1 \
        && echo "[cgc-db] $_vm_pkg → private (corrected)" \
        || echo "::error::[cgc-db] could NOT make $_vm_pkg private — private source is exposed, fix in the GitHub UI now"
    else
      echo "[cgc-db] $_vm_pkg visibility=$_vm_vis (correct — indexes private repo(s):$_vm_priv)"
    fi
  else
    echo "[cgc-db] $_vm_pkg visibility=$_vm_vis (no private repo in index_repos)"
  fi
}

# ── main ─────────────────────────────────────────────────────────────────
main() {
SRC="${1:?usage: cloud-cgc-db-package.sh <src_dir> <image> [tag]}"
IMAGE="${2:?image required}"
TAG="${3:-latest}"
PKG="${IMAGE##*/}"
[ -d "$SRC" ] || { echo "::error::src dir not found: $SRC"; exit 1; }

# MODE auto-detection from the image name — see file header + detect_mode().
# Override escape hatch: CGC_PKG_MODE (tests / edge cases only, unset in
# every real caller).
_dm=$(detect_mode "$PKG")
case "$_dm" in
  base)   _mode=base ;;
  repo:*) _mode=repo; LOCAL_NAME="${_dm#repo:}" ;;
  *)      _mode=monolith ;;
esac
MODE="${CGC_PKG_MODE:-$_mode}"
[ "$MODE" = repo ] && [ -z "${LOCAL_NAME:-}" ] && LOCAL_NAME="${PKG#cgc-db-}"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/ctx"

case "$MODE" in
  base)
    build_base_tar "$SRC" "$WORK/ctx/octocode-db.tar"
    DESC="cloud-cgc-mcp octocode DB BASE — octocode home ROOT state (config.toml + fastembed/ + sentencetransformer/ model caches), no project data. Consumers restore this ONCE per octocode home, then layer each cgc-db-<repo>:latest on top via cp -a. Embedding models must stay pinned identical everywhere — a mismatch silently drop_tables a repo."
    ;;
  repo)
    PROJ=$(find_project_dir "$SRC") || exit 1
    echo "[cgc-db] $PKG · single project dir detected: $PROJ"
    build_repo_tar "$SRC" "$WORK/ctx/octocode-db.tar" "$PROJ"
    DESC="cloud-cgc-mcp octocode DB for $LOCAL_NAME (single <project_id>/ dir: semantic FastEmbed vectors + GraphRAG graph). Visibility matches the $LOCAL_NAME repo. Restore into an octocode home ROOTED by cgc-db-base:latest via cp -a."
    ;;
  monolith|*)
    tar cf "$WORK/ctx/octocode-db.tar" -C "$SRC" .
    DESC="cloud-cgc-mcp octocode DB (semantic FastEmbed vectors + GraphRAG graph). Single GHCR upstream; restore into the octocode home (~/.local/share/octocode or the octocode_db volume) via cloud-cgc-db-pull.sh."
    ;;
esac
[ -s "$WORK/ctx/octocode-db.tar" ] || { echo "::error::empty DB tar from $SRC (mode=$MODE)"; exit 1; }
echo "[cgc-db] packaged $(du -h "$WORK/ctx/octocode-db.tar" | cut -f1) from $SRC (mode=$MODE)"

# Minimal image: ADD auto-extracts the tar to /octocode-db. Restored by the
# consumer (cloud-cgc-db-pull.sh for monolith; cp -a for base/repo).
cat > "$WORK/ctx/Dockerfile" <<DOCKER
FROM busybox:latest
ADD octocode-db.tar /octocode-db
LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud-infra"
LABEL org.opencontainers.image.description="$DESC"
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
# NOTE: the per-repo/base images are far smaller than the monolith (one project dir /
# model caches, not the whole 16G home), but the hygiene below is harmless and still
# correct to run for them — it just reclaims less.
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

# VISIBILITY — dispatched per mode (see the visibility_* functions above).
if command -v gh >/dev/null 2>&1; then
  case "$MODE" in
    repo)     visibility_repo "$PKG" "$LOCAL_NAME" ;;
    base)     visibility_base "$PKG" ;;
    monolith) visibility_monolith "$PKG" ;;
  esac
fi
echo "[cgc-db] DONE → $IMAGE:$TAG (mode=$MODE)"
}

[ "${CGC_PKG_SOURCE_ONLY:-0}" = "1" ] || main "$@"
