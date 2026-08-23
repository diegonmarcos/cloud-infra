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
#  build_base_tar / build_repo_tar / resolve_repo_source_label /
#  resolve_repo_desired_visibility / verify_or_delete_repo_pkg / visibility_* /
#  push_with_retry directly against the real logic (stubbing gh/docker/jq as
#  needed) instead of maintaining a parallel copy.
#
#  INCIDENT (2026-08-22, run 32574580997): cgc-db-cloud-data — the GHCR index of
#  the PRIVATE cloud-data repo — was created PUBLIC and had to be emergency-
#  deleted. Root cause, two parts:
#   (a) GitHub's package REST API has NO set-visibility endpoint for user
#       packages — PUT and PATCH both 404. Every "correct visibility via gh api"
#       call below this comment used to silently no-op, including the fail-safe
#       that was supposed to force cgc-db-cloud-data back to private. The ONLY
#       verb that actually works is DELETE /user/packages/container/<name>.
#   (b) GHCR auto-links a brand-new package to whatever repo its
#       org.opencontainers.image.source LABEL names, and the CREATED visibility
#       is inherited from THAT repo. This file hardcoded the LABEL to the
#       PUBLIC cloud-infra repo on every image, repo mode included — so a
#       private repo's very first per-repo checkpoint was born public, before
#       any visibility check downstream ever ran.
#  Fixed here: repo mode's LABEL now resolves to the TARGET repo
#  (resolve_repo_source_label) so the package is correct BY CONSTRUCTION, and a
#  post-push BACKSTOP (verify_or_delete_repo_pkg) deletes-and-fails instead of
#  pretending a dead PUT fixed anything. base/monolith modes are unaffected —
#  their LABEL stays cloud-infra, see each mode's block in main() below.
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
  if [ -n "$_rbj_root" ] && [ -f "$_rbj_root/a_solutions/user-ai_cloud-cgc-pub-mcp/build.json" ]; then
    printf '%s\n' "$_rbj_root/a_solutions/user-ai_cloud-cgc-pub-mcp/build.json"
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

# REPO-MODE PROJECT DIR RESOLUTION. CGC_PROJECT_DIR (env, optional): the caller
# (cloud-cgc-db-update.sh's per-repo loop, STRAY-SELECT) may already know exactly
# which project dir this checkpoint is for, resolved via a before/after diff
# around its own `octocode index` call rather than a bare count over the whole
# SRC dir — which is what find_project_dir() does, and which production
# incident (run 32572923354) showed is the WRONG invariant whenever a stray dir
# (from anywhere) sits in SRC alongside the real one. When the caller passes an
# answer, trust it (still validated: must exist as a dir under SRC, so a typo'd
# or stale CGC_PROJECT_DIR fails loudly rather than silently packaging nothing)
# and skip find_project_dir() entirely. Any caller that does not set it —
# including every caller of this script that predates STRAY-SELECT — gets the
# exact original exactly-one behaviour, unchanged.
resolve_repo_project_dir() { # $1=SRC → stdout: project dir name; rc!=0 on failure
  _rrp_src="$1"
  if [ -n "${CGC_PROJECT_DIR:-}" ]; then
    [ -d "$_rrp_src/$CGC_PROJECT_DIR" ] || {
      echo "::error::[cgc-db] CGC_PROJECT_DIR='$CGC_PROJECT_DIR' does not exist under $_rrp_src" >&2
      return 1
    }
    echo "[cgc-db] project dir given by caller (before/after diff): $CGC_PROJECT_DIR" >&2
    printf '%s\n' "$CGC_PROJECT_DIR"
    return 0
  fi
  find_project_dir "$_rrp_src"
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

# ONE local_name -> GitHub remote-name lookup (cloud/repos.json, via
# .runtime.octocode.repo_map), shared by the LABEL resolver
# (resolve_repo_source_label, pre-push) and the visibility resolver
# (resolve_repo_desired_visibility, post-push) so repo_map is only ever read
# one way. rc!=0 (empty stdout) when build.json is unreadable or local_name
# isn't a repo_map key — every caller must fail safe on that, never assume
# public.
resolve_remote_name() { # $1=LOCAL_NAME → stdout: remote name; rc!=0 if unresolved
  _rrn_bj=$(resolve_bj) || return 1
  _rrn_remote=$(jq -r --arg l "$1" '.runtime.octocode.repo_map[$l] // empty' "$_rrn_bj" 2>/dev/null)
  [ -n "$_rrn_remote" ] || return 1
  printf '%s\n' "$_rrn_remote"
}

# LABEL PER TARGET — repo mode (ITEM 1, the actual fix; see file header for the
# incident). GHCR auto-links a NEW package to whatever repo
# org.opencontainers.image.source names, and the CREATED visibility inherits
# THAT repo's visibility. Point the LABEL at the repo actually being packaged
# instead of the hardcoded (public) cloud-infra: private repo → private
# package, correct by construction — no visibility check needed after the
# fact for the common case. If local_name can't be resolved (repo_map/registry
# drift), OMIT the LABEL rather than falling back to cloud-infra: an unlinked
# package is not known to inherit PUBLIC from anywhere, and the post-push
# verify_or_delete_repo_pkg() backstop still catches it if it somehow comes up
# public anyway.
resolve_repo_source_label() { # $1=PKG (for error msg) $2=LOCAL_NAME → stdout: LABEL value; rc 1 (empty stdout) if unresolved
  _rsl_remote=$(resolve_remote_name "$2") || {
    echo "::error::[cgc-db] $1: cannot resolve GitHub URL for local_name '$2' (repo_map lookup failed) — omitting org.opencontainers.image.source LABEL; the post-push visibility backstop will delete the package if it ends up public"
    return 1
  }
  printf 'https://github.com/diegonmarcos/%s\n' "$_rsl_remote"
}

# Shared desired-visibility resolver for repo mode: local_name -> repo_map ->
# remote -> `gh repo view --json isPrivate`. Sets _rdv_desired (private|public)
# and _rdv_remote (resolved remote, or empty if unresolved) as globals for the
# caller — used only by verify_or_delete_repo_pkg() below. Fail-safe in every
# direction that leaves the desired visibility undetermined: unmapped
# local_name, an unreadable build.json, or a `gh repo view` failure all
# resolve to private.
resolve_repo_desired_visibility() { # $1=PKG (for error msg) $2=LOCAL_NAME
  _rdv_pkg="$1"; _rdv_local="$2"
  _rdv_remote=$(resolve_remote_name "$_rdv_local") || _rdv_remote=""
  if [ -z "$_rdv_remote" ]; then
    _rdv_desired=private
    echo "::error::[cgc-db] $_rdv_pkg: local_name '$_rdv_local' not found in repo_map (or build.json unreadable) — fail-safe: treating as private"
  else
    _rdv_ispriv=$(gh repo view "diegonmarcos/$_rdv_remote" --json isPrivate --jq .isPrivate 2>/dev/null || echo "")
    case "$_rdv_ispriv" in
      true)  _rdv_desired=private ;;
      false) _rdv_desired=public ;;
      *)
        _rdv_desired=private
        echo "::error::[cgc-db] $_rdv_pkg: could not determine visibility of diegonmarcos/$_rdv_remote — fail-safe: treating as private"
        ;;
    esac
  fi
}

# VERIFY-OR-DELETE BACKSTOP — repo mode (ITEM 2). GitHub's package REST API has
# NO set-visibility endpoint (PUT/PATCH both 404, see file header) — a "force
# it back to private" call can never actually fix a public package, so don't
# pretend one does. Instead: after the push, ask what visibility the package
# ACTUALLY got created/left with. A public-desired repo skips the check
# entirely (nothing to leak, not worth the extra API call). A private-desired
# repo (including every fail-safe-undetermined case from
# resolve_repo_desired_visibility) whose package is not private is an active
# leak: log it loudly, DELETE the package (the one verb that works), and exit
# 1 — the artifact must not survive being public. This is the backstop for
# resolve_repo_source_label() above: normally the LABEL fix alone means this
# function finds everything already correct and returns 0 immediately.
# PRE-PUSH GATE — the only place a private repo's leak can actually be PREVENTED
# rather than cleaned up after.
#
# verify_or_delete_repo_pkg() below runs AFTER `docker push`. By the time it
# fires, a package that GHCR created public has already existed, publicly, with
# a private repo's embedded source inside it, for as long as the push + the API
# round-trip took. Deleting it afterwards limits the damage; it does not prevent
# it. That window has opened on every single run for cloud-data and
# my-ai_memory, because GHCR creates a NEW package with the visibility of the
# pushing context (cloud-infra, public) -- the org.opencontainers.image.source
# LABEL auto-link does not reliably win the race at creation time, which is what
# the PAT was expected to fix and did not.
#
# GitHub has no create-package and no set-visibility API, so a package cannot be
# born private from here. But an EXISTING private package keeps its visibility
# across pushes. That gives an exact, checkable precondition:
#
#   repo public                    -> push (nothing to protect)
#   repo private, pkg private      -> push (visibility is preserved, not set)
#   repo private, pkg public       -> refuse, ::error:: (already leaking; do not
#                                     feed it fresher private data)
#   repo private, pkg absent       -> refuse, ::warning:: (a push would CREATE it
#                                     public -- this is today's state, and it is
#                                     unblocked by one manual UI step, below)
#
# Absent is a WARNING and rc 0, not an error, on purpose: it is the correct,
# expected state until cloud-cgc-pvt-mcp exists to consume these images, and
# there is nothing broken to fix -- the DB simply is not published yet. Failing
# the run would paint red a pipeline whose public half is entirely healthy. It
# is loud (a GHA annotation on every run) so it cannot rot silently.
#
# To unblock, once there is a private consumer: create the package once in the
# GitHub UI as PRIVATE (push any placeholder to ghcr.io/<owner>/<pkg>, then
# Package settings -> Change visibility -> Private), and every subsequent push
# from here inherits it. Seed it with a CONTENT-FREE placeholder, never with a
# real DB, so nothing private is ever exposed even briefly.
gate_repo_push() { # $1=PKG $2=LOCAL_NAME → rc 0 = push allowed; exits the WHOLE SCRIPT otherwise
  _gp_pkg="$1"; _gp_local="$2"
  resolve_repo_desired_visibility "$_gp_pkg" "$_gp_local"
  if [ "$_rdv_desired" = "public" ]; then
    return 0
  fi
  _gp_vis=$(gh api "/user/packages/container/${_gp_pkg}" --jq '.visibility' 2>/dev/null || echo absent)
  case "$_gp_vis" in
    private)
      echo "[cgc-db] $_gp_pkg: repo diegonmarcos/${_rdv_remote:-?} is private and the package already exists private — pushing (visibility is preserved across pushes)"
      return 0
      ;;
    absent)
      # A fresh package is born with the visibility of whatever the PUSH token
      # links it to, so whether this is safe depends entirely on that token:
      #
      #   PAT that can see the private repo -> org.opencontainers.image.source
      #     auto-links to that repo and the package is created PRIVATE. Verified
      #     with content-free probes 2026-08-23: private at t+0s, linked
      #     diegonmarcos/cloud-data, no propagation race.
      #   GITHUB_TOKEN -> GHCR associates the push with the WORKFLOW's repo
      #     (cloud-infra, public) and the package is created PUBLIC with private
      #     source inside it, regardless of the LABEL.
      #
      # CGC_GHCR_PAT is only ever tested for emptiness here, never printed or
      # passed on. It reaches this script from the workflow env alongside
      # GHCR_TOKEN, which is the variable cloud-cgc-db-update.sh actually logs
      # in with -- they come from the same secret, so non-empty here means the
      # push is PAT-authenticated.
      #
      # _rdv_ispriv = "true" is required as well, and is the stricter half: it
      # means `gh repo view` POSITIVELY resolved the repo as private. The
      # resolver also reports "private" as a fail-safe when it could not tell
      # (unreadable repo_map, no API reach), and that case must NOT push -- a
      # token that cannot see the repo is exactly the token that cannot
      # auto-link it either.
      if [ -n "${CGC_GHCR_PAT:-}" ] && [ "${_rdv_ispriv:-}" = "true" ]; then
        echo "[cgc-db] $_gp_pkg: repo diegonmarcos/${_rdv_remote:-?} is private, no package yet — pushing PAT-authenticated so GHCR creates it PRIVATE via the source LABEL"
        return 0
      fi
      echo "::warning::[cgc-db] $_gp_pkg NOT PUBLISHED — repo diegonmarcos/${_rdv_remote:-unresolved} is private and no package exists, but the push is not PAT-authenticated (or the repo could not be positively resolved), so GHCR would create it PUBLIC with private source inside. Skipping the push entirely — nothing is exposed. Fix by setting the CGC_GHCR_PAT secret (repo + read:packages + delete:packages)."
      exit 0
      ;;
    *)
      echo "::error::[cgc-db] $_gp_pkg already exists as $_gp_vis but repo diegonmarcos/${_rdv_remote:-unresolved} is private — refusing to push fresher private data into an exposed package. DELETE OR PRIVATE IT IN THE GITHUB UI NOW"
      exit 1
      ;;
  esac
}

verify_or_delete_repo_pkg() { # $1=PKG $2=LOCAL_NAME → rc 0 ok/skip; exits the WHOLE SCRIPT (not just this fn) on a caught leak
  _vd_pkg="$1"; _vd_local="$2"
  resolve_repo_desired_visibility "$_vd_pkg" "$_vd_local"
  if [ "$_rdv_desired" = "public" ]; then
    echo "[cgc-db] $_vd_pkg: repo diegonmarcos/${_rdv_remote:-?} is public — skipping post-push visibility check"
    return 0
  fi
  _vd_vis=$(gh api "/user/packages/container/${_vd_pkg}" --jq '.visibility' 2>/dev/null || echo unknown)
  if [ "$_vd_vis" = "private" ]; then
    echo "[cgc-db] $_vd_pkg visibility=private (correct — repo diegonmarcos/${_rdv_remote:-unresolved} is private or undetermined)"
    return 0
  fi
  echo "::error::[cgc-db] $_vd_pkg is $_vd_vis but must be private (repo diegonmarcos/${_rdv_remote:-unresolved} is private or undetermined) — GitHub's package API cannot SET visibility (no PUT/PATCH endpoint), deleting instead of leaving private source exposed"
  gh api --method DELETE "/user/packages/container/${_vd_pkg}" >/dev/null 2>&1 \
    && echo "::error::[cgc-db] $_vd_pkg DELETED (was $_vd_vis, repo is private) — re-run packaging once any repo_map/registry drift is fixed" \
    || echo "::error::[cgc-db] could NOT delete $_vd_pkg — private source may still be exposed, delete it in the GitHub UI NOW"
  exit 1
}

# VISIBILITY — base mode. No associated repo, and none is needed: the base
# image carries model caches + config only (ARCHITECTURE), never project
# content, so there is nothing to leak. Should always be public, for pull
# convenience. GitHub's package REST API has NO set-visibility endpoint
# (PUT/PATCH both 404, see file header) so a drift here cannot be
# auto-corrected — only reported. Warning only, never ::error::: a private
# base package is an inconvenience (still pullable to anyone already
# docker-logged-in), never a leak.
visibility_base() { # $1=PKG
  _vb_pkg="$1"
  _vb_vis=$(gh api "/user/packages/container/${_vb_pkg}" --jq '.visibility' 2>/dev/null || echo unknown)
  if [ "$_vb_vis" = "public" ]; then
    echo "[cgc-db] $_vb_pkg visibility=public (correct — base image carries no project content)"
    return 0
  fi
  echo "::warning::[cgc-db] $_vb_pkg visibility=$_vb_vis (want public) — cannot auto-correct: GitHub's package API has no set-visibility endpoint. Fix by hand in the GitHub UI, or ignore (base image carries no project content to leak)."
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

# VISIBILITY — monolith mode.
#
# The octocode DB is a searchable index of the FULL CONTENT of every repo in
# .runtime.octocode.index_repos, and that list includes cloud-data, which is a
# PRIVATE repo (it needs CGC_DEPLOY_KEY_cloud_data to clone at all). Publishing
# this image therefore publishes private source, embedded and reconstructible,
# to anyone who can docker pull.
#
# Detect the invariant (if any index_repo is private, the package must be
# private) and report loudly on drift — see the ::error:: branch below for why
# this can only REPORT, not correct, since 2026-08-22 (GitHub's package API
# has no set-visibility endpoint). Consumers pull with credentials (oci-apps
# and the runner both already docker login to GHCR), so private costs nothing
# operationally.
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
      # GitHub's package REST API has NO set-visibility endpoint (PUT/PATCH both
      # 404, see file header) — a "force private" PUT here always silently
      # no-ops, which is exactly how this branch used to print an ::error:: and
      # then ALSO silently fail to fix anything, while the script kept going
      # and CI stayed green with private source exposed. Kept LOUD (unlike
      # base) because this DOES leak: cloud-data is private and this image
      # indexes its full content. No DELETE backstop here — unlike per-repo
      # packaging (verify_or_delete_repo_pkg), the monolith image is not
      # something this script can safely delete-and-recreate mid-run (see
      # db_publish's header comment: it stays the legacy path until the
      # per-repo matrix is proven green). Manual fix in the GitHub UI is
      # required until the monolith path is retired.
      echo "::error::[cgc-db] $_vm_pkg is PUBLIC but indexes private repo(s):$_vm_priv — GitHub's package API cannot fix this (no set-visibility endpoint) — DELETE OR PRIVATE IT IN THE GITHUB UI NOW, private source is exposed"
    else
      echo "[cgc-db] $_vm_pkg visibility=$_vm_vis (correct — indexes private repo(s):$_vm_priv)"
    fi
  else
    echo "[cgc-db] $_vm_pkg visibility=$_vm_vis (no private repo in index_repos)"
  fi
}

# PUSH RETRY (ITEM 4). cloud-android died on run 32574580997 mid-run: a
# transient `docker push` failure AFTER a perfect index+package, no retry, so
# a checkpoint that had done all the real (expensive) work was thrown away
# over a flaky network blip. 3 attempts, short linear backoff (5s, 10s)
# between them, preserving the REAL docker exit code on final failure — the
# caller (cloud-cgc-db-update.sh) branches on that exit code, so swallowing it
# into a generic 1 would be its own bug. CGC_PUSH_RETRY_SLEEP overrides the
# backoff (used by the test harness to run this in well under a second; unset
# in every real caller).
push_with_retry() { # $1=IMAGE:TAG → rc: 0 on success, else the LAST docker push's exit code after 3 attempts
  _pwr_ref="$1"
  _pwr_max=3
  _pwr_attempt=1
  while [ "$_pwr_attempt" -le "$_pwr_max" ]; do
    # `docker push ... && return 0` (NOT `if docker push ...; then return 0; fi`).
    # Bash/POSIX quirk verified against a minimal repro: an `if` compound whose
    # condition is false and has no `else` reports exit status 0 for the WHOLE
    # `if`, not the failing condition's own code ("or zero if no condition
    # tested true" — bash(1)) — so `_pwr_rc=$?` right after `fi` always read 0,
    # never the real docker rc. That made `return "$_pwr_rc"` return 0 on EVERY
    # path, including all-3-attempts-failed: the caller's
    # `push_with_retry ... || exit $?` would never fire, and the script would
    # sail on to `docker rmi` / visibility checks / "DONE" as if a never-pushed
    # image had shipped. `&&` is a short-circuit list, not an `if`: on failure
    # $? IS the failed command's own code, and being non-final in an AND-OR
    # list it is also exempt from `set -e` (only cmd1 ran; cmd2 didn't).
    docker push "$_pwr_ref" && return 0
    _pwr_rc=$?
    if [ "$_pwr_attempt" -lt "$_pwr_max" ]; then
      _pwr_sleep="${CGC_PUSH_RETRY_SLEEP:-$((_pwr_attempt * 5))}"
      echo "::warning::[cgc-db] docker push attempt $_pwr_attempt/$_pwr_max failed (rc=$_pwr_rc) for $_pwr_ref — retrying in ${_pwr_sleep}s" >&2
      sleep "$_pwr_sleep"
    fi
    _pwr_attempt=$((_pwr_attempt + 1))
  done
  echo "::error::[cgc-db] docker push failed after $_pwr_max attempts for $_pwr_ref (rc=$_pwr_rc)" >&2
  return "$_pwr_rc"
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
    DESC="cloud-cgc-pub-mcp octocode DB BASE — octocode home ROOT state (config.toml + fastembed/ + sentencetransformer/ model caches), no project data. Consumers restore this ONCE per octocode home, then layer each cgc-db-<repo>:latest on top via cp -a. Embedding models must stay pinned identical everywhere — a mismatch silently drop_tables a repo."
    SRC_URL="https://github.com/diegonmarcos/cloud-infra"
    ;;
  repo)
    # BEFORE the tar+build, not just before the push: if this repo may not be
    # published, there is no reason to spend ~15 min tarring and building a
    # multi-GB image that gets thrown away.
    gate_repo_push "$PKG" "$LOCAL_NAME"
    PROJ=$(resolve_repo_project_dir "$SRC") || exit 1
    build_repo_tar "$SRC" "$WORK/ctx/octocode-db.tar" "$PROJ"
    DESC="cloud-cgc-pub-mcp octocode DB for $LOCAL_NAME (single <project_id>/ dir: semantic FastEmbed vectors + GraphRAG graph). Visibility matches the $LOCAL_NAME repo. Restore into an octocode home ROOTED by cgc-db-base:latest via cp -a."
    # ITEM 1 — LABEL PER TARGET (see resolve_repo_source_label + file header).
    # Empty SRC_URL (repo_map/registry drift) means the LABEL is OMITTED below,
    # not defaulted to cloud-infra — verify_or_delete_repo_pkg() is the backstop.
    SRC_URL=$(resolve_repo_source_label "$PKG" "$LOCAL_NAME") || SRC_URL=""
    ;;
  monolith|*)
    tar cf "$WORK/ctx/octocode-db.tar" -C "$SRC" .
    DESC="cloud-cgc-pub-mcp octocode DB (semantic FastEmbed vectors + GraphRAG graph). Single GHCR upstream; restore into the octocode home (~/.local/share/octocode or the octocode_db volume) via cloud-cgc-db-pull.sh."
    SRC_URL="https://github.com/diegonmarcos/cloud-infra"
    ;;
esac
[ -s "$WORK/ctx/octocode-db.tar" ] || { echo "::error::empty DB tar from $SRC (mode=$MODE)"; exit 1; }
echo "[cgc-db] packaged $(du -h "$WORK/ctx/octocode-db.tar" | cut -f1) from $SRC (mode=$MODE)"

# Minimal image: ADD auto-extracts the tar to /octocode-db. Restored by the
# consumer (cloud-cgc-db-pull.sh for monolith; cp -a for base/repo).
cat > "$WORK/ctx/Dockerfile" <<DOCKER
FROM busybox:latest
ADD octocode-db.tar /octocode-db
DOCKER
# org.opencontainers.image.source drives GHCR's auto-link (see file header) —
# base/monolith always carry it (cloud-infra); repo mode carries it ONLY when
# resolve_repo_source_label() above resolved a target repo. Omitted (not
# defaulted) on failure — see that function's comment for why.
if [ -n "$SRC_URL" ]; then
  printf 'LABEL org.opencontainers.image.source="%s"\n' "$SRC_URL" >> "$WORK/ctx/Dockerfile"
fi
cat >> "$WORK/ctx/Dockerfile" <<DOCKER
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
push_with_retry "$IMAGE:$TAG" || exit $?
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

# VISIBILITY — dispatched per mode (see the functions above). repo mode's
# check is the ITEM 2 verify-or-delete BACKSTOP, not a "correct it" pass —
# resolve_repo_source_label() earlier is what makes the package correct BY
# CONSTRUCTION; this only catches (and kills) it if that still wasn't enough.
if command -v gh >/dev/null 2>&1; then
  case "$MODE" in
    repo)     verify_or_delete_repo_pkg "$PKG" "$LOCAL_NAME" ;;
    base)     visibility_base "$PKG" ;;
    monolith) visibility_monolith "$PKG" ;;
  esac
fi
echo "[cgc-db] DONE → $IMAGE:$TAG (mode=$MODE)"
}

[ "${CGC_PKG_SOURCE_ONLY:-0}" = "1" ] || main "$@"
