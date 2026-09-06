#!/usr/bin/env bash
# ── Generate per-container build-{name}.json + cloud-data-{name}.json ──
#
# Runs `bash build.sh config` to regenerate dist/ from a_solutions/*/build.json.
# The regenerated files are committed by the standard ci flow (the workflow
# caller commits + pushes), not from inside this script.
#
# 2026-04-27: removed the previous `cd 1_cicd/dist && git push` block. It
# assumed 1_cicd/dist/ was the cloud-data submodule — it is NOT (it is a
# regular subdir of the cloud repo). The push was either a no-op (no changes)
# or hit the cloud repo's own origin. The cloud-data submodule (I_cloud-data/)
# is now frozen — every container reads its own build-{containername}.json.
#
# Usage: ship-gen-configs.sh
set -euo pipefail

REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT"
export GIT_BASE="${GIT_BASE:-$(dirname "$REPO_ROOT")}"

# ── Assert the a_solutions worktree is populated before deriving ──
#
# This block used to re-pin a_solutions to the superproject gitlink. That was
# the 2026-09-03 fix for a silent-stale-config bug: the cloud-builder
# entrypoint re-syncs this mounted workspace with `git nuke`, whose final step
# ran `git submodule update --init --recursive --remote --rebase --force`, and
# `--remote` checks a submodule out to its REMOTE BRANCH TIP rather than the
# pinned SHA — so derive read OLD build.json files and the commit step then
# reported "dist/ unchanged — nothing to commit".
#
# a_solutions stopped being a submodule on 2026-09-06. There is no gitlink to
# pin to and `git submodule update` can no longer move it, because the
# workflow's actions/checkout already put the exact commit the containers-push
# dispatch announced on disk. The old guard did not merely become redundant,
# it became FATAL: `git rev-parse HEAD:a_solutions` does not fail on an
# unresolvable rev, it ECHOES THE ARGUMENT BACK on stdout, so `_expected_sol`
# was set to the literal string "HEAD:a_solutions", passed the non-empty
# check, and then mismatched every real SHA — aborting every gen-configs run.
#
# One hazard survives in a new shape, so the assertion stays: a_solutions is
# untracked AND gitignored in this repo now, which means any `git clean -fdx`
# over this workspace would erase it outright. derive would then read ZERO
# build.json files and happily emit a config with every service missing —
# worse than stale. Assert the tree is populated and fail loud.
_sol_dir="$REPO_ROOT/a_solutions"
_sol_count=$(find "$_sol_dir" -mindepth 2 -maxdepth 2 -name build.json 2>/dev/null | wc -l | tr -d ' ')
if [ ! -d "$_sol_dir" ] || [ "${_sol_count:-0}" -eq 0 ]; then
  echo "::error::gen-configs: ${_sol_dir} contains no <service>/build.json (found ${_sol_count:-0})." >&2
  echo "::error::  Refusing to derive a config with every service missing. a_solutions is a SEPARATE repository (cloud-u-containers) that the workflow checks out; if it is absent here something erased it — a \`git clean -fdx\` will, because the path is gitignored in this repo." >&2
  exit 1
fi
echo "── a_solutions present at $(git -C "$_sol_dir" rev-parse --short HEAD 2>/dev/null || echo '<not a git checkout>') with ${_sol_count} service build.json file(s) ──"

echo "── Generating cloud-data + build-{name}.json ──"
bash build.sh config
echo "── Done. Generated files staged in dist/ — caller commits + pushes. ──"
