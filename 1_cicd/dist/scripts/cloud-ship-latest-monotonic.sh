#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_cicd/src/scripts/cloud-ship-latest-monotonic.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ cloud-ship-latest-monotonic.sh — refuse to move :latest BACKWARDS         ║
# ╚══════════════════════════════════════════════════════════════════════════╝
#
# WHY THIS EXISTS (#358, hazard found by agent V)
#
# Two Ship runs for the SAME image can be in flight at once from different
# commits. Each is pinned to the SHA its dispatch announced, each builds that
# tree, and each then overwrites `:latest`. Whichever FINISHES last wins —
# which has nothing to do with which commit is newer. V caught the pair live:
#
#     35043145083  Ship → Reports image  in_progress   <- commit 2489897f (new)
#     35043096780  Ship → Reports image  in_progress   <- commit 1e87f8d1 (old)
#
# If the older one lands second, `:latest` silently reverts to a tree without
# the newer fix, BOTH runs go green, and every dashboard reports the change
# shipped. The next deploy then pulls the reverted image. Nothing in the
# pipeline says a word: this is a green run that un-ships a fix.
#
# Serialising the publishers (a `concurrency:` block) makes the pair rarer but
# cannot make it impossible — a manual re-run, a second workflow, or a
# retried job can still publish out of order, and concurrency groups are
# per-workflow while `:latest` is global to the image. So the tag move itself
# has to be guarded. This script is that guard, and it is the real fix.
#
# HOW "BACKWARDS" IS DECIDED, WITHOUT A NEW LABEL ON THE IMAGE
#
# The obvious design is to stamp org.opencontainers.image.revision into every
# image and read it back. Measured 2026-09-16, our images do NOT carry it —
# only ...image.source — so that design would require changing the build path
# for every service before the guard could work anywhere. That build path is
# the hot path several agents are shipping through right now, and an unproven
# change to it is exactly the kind of risk this ticket exists to remove.
#
# The registry already holds the fact, in a form nobody has to add: every
# publisher tags `:<short-sha>` alongside `:latest`. So the question
#
#     "is the image :latest currently points at built from a commit NEWER
#      than the one I am about to publish?"
#
# is answered by walking only the commits that are newer than ours —
# `git rev-list <ours>..<branch>`, which is normally zero to a handful of
# entries — and asking whether `:latest` resolves to the same digest as any of
# THEIR `:<short-sha>` tags. If it does, a newer commit already published and
# we would be reverting it. Bounded, exact, and it needs nothing added to the
# image. Listing the repository's tags instead would be neither: GHCR paginates
# them and the answer would cost one HTTP HEAD per tag, per publish.
#
# WHAT IT DELIBERATELY DOES NOT DO
#
# It does not compare timestamps. A commit date is attacker- and rebase-
# controlled and says nothing about ancestry; git's own ancestry graph is the
# only thing that actually orders two commits.
#
# It does not refuse when it cannot decide. An image whose `:latest` matches
# none of the newer commits' tags is the NORMAL case (we are the newest), and
# an image with no `:latest` at all is a first publish. Refusing on
# "don't know" would wedge every publisher the first time it ran. The one
# thing it will not do is stay silent: an undecidable case is printed.
#
# RESIDUAL WINDOW, STATED
#
# The check and the tag move are not atomic. Two publishers that both pass the
# check within the same second can still race. That window is seconds wide
# against builds that take minutes, and the `concurrency:` block on the calling
# workflow closes it in practice by serialising the publishers. Closing it
# absolutely needs a registry-side compare-and-swap, which the Docker registry
# API does not offer. This is a real limit, not a dismissed one.
#
# CONTRACT
#
#   argv   : <image_no_tag> <our_commit> [src_repo_dir] [branch_ref]
#   stdout : the reasoning, one line per decision
#   exit 0 : safe — :latest does not currently hold a newer commit's image
#   exit 3 : REFUSE — :latest holds an image built from a DESCENDANT commit
#
# Seams (so the tester needs neither a registry nor a network):
#   MONOTONIC_DIGEST_CMD <ref>              -> the digest <ref> resolves to
#   MONOTONIC_REVLIST_CMD <ours> <branch>   -> commits newer than <ours>

set -uo pipefail

IMAGE="${1:-}"
OURS="${2:-}"
SRC_DIR="${3:-.}"
BRANCH="${4:-origin/main}"

[ -n "$IMAGE" ] && [ -n "$OURS" ] || {
  echo "usage: $0 <image_no_tag> <our_commit> [src_repo_dir] [branch_ref]" >&2
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Which tag spelling carries the SOURCE commit for this image.
#
# It is not always the bare short sha. ship-reports.yml tags `:<sha>` with
# cloud-infra's OWN commit, while the image's content — and therefore the
# ordering that matters — comes from the cloud-u-containers commit the dispatch
# announced. Comparing against the wrong repository's history would make this
# guard look healthy and fire never, which is worse than not having it: a
# guard that cannot fire is a claim of safety with nothing behind it. The
# caller states which prefix names the source commit, and publishes that tag.
PFX="${MONOTONIC_TAG_PREFIX:-}"

# Resolve a ref to the SET of digests that identify it, as one comparable
# string. Defaults to the shared resolver so this guard and the drift engines
# agree on what a tag currently means.
#
# A set, not one element. The resolver emits the index digest AND every
# per-arch child, and the first version of this function took
# `sort -u | head -n1` — which for a multi-arch tag returns whichever digest
# sorts first, a CHILD, not the index. The equality test still happened to be
# right (both sides pick the same representative from identical sets), but the
# guard then PRINTED a child digest as if it were what `:latest` points at.
# Caught in its own first live run, 35047596807:
#   "monotonic: …:latest currently = sha256:0253c344…"   <- a child of 9e0c1f4e…
# A guard that misreports the thing it just read is one nobody will trust the
# day it actually refuses, so it compares the whole set and says the whole set.
digest_set() {
  if [ -n "${MONOTONIC_DIGEST_CMD:-}" ]; then
    $MONOTONIC_DIGEST_CMD "$1"
  else
    bash "$SCRIPT_DIR/cloud-ship-registry-digest.sh" "$1"
  fi | grep '^sha256:' | sort -u | paste -sd, -
}

# Commits strictly newer than ours on the branch. Empty is the normal answer.
revlist_newer() {
  if [ -n "${MONOTONIC_REVLIST_CMD:-}" ]; then
    $MONOTONIC_REVLIST_CMD "$1" "$2"
  else
    git -C "$SRC_DIR" rev-list "$1..$2" 2>/dev/null
  fi
}

CUR="$(digest_set "$IMAGE:latest")"
if [ -z "$CUR" ]; then
  echo "monotonic: $IMAGE:latest does not resolve yet — first publish, nothing to move backwards over"
  exit 0
fi
echo "monotonic: $IMAGE:latest currently = $CUR"

NEWER="$(revlist_newer "$OURS" "$BRANCH")"
if [ -z "$NEWER" ]; then
  echo "monotonic: no commits newer than ${OURS} on ${BRANCH} — we are the tip, publishing is forward"
  exit 0
fi

echo "monotonic: $(printf '%s\n' "$NEWER" | grep -c .) commit(s) newer than ${OURS} — checking whether one of them already published"
for c in $NEWER; do
  for short in "${PFX}${c:0:7}" "${PFX}${c:0:8}" "${PFX}${c:0:12}" "${PFX}${c}"; do
    d="$(digest_set "$IMAGE:$short")"
    [ -n "$d" ] || continue
    if [ "$d" = "$CUR" ]; then
      echo "::error::REFUSING to move $IMAGE:latest backwards. It currently holds the image built from $c, which is a DESCENDANT of the commit this run is publishing ($OURS). Overwriting it would silently revert that commit's changes while this run reported success — the exact failure this guard exists to stop. Nothing was pushed. If you genuinely intend to roll back, retag deliberately rather than racing :latest."
      exit 3
    fi
    break   # this commit has a tag under one spelling; no need to try others
  done
done

echo "monotonic: none of the newer commits owns $IMAGE:latest — publishing is forward"
exit 0
