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

# ── Re-pin a_solutions to the recorded gitlink (undo `git nuke --remote` drift) ──
#
# ROOT CAUSE of the silent-stale-config bug (2026-09-03): the cloud-builder
# entrypoint (cb_containers-builders/src/docker/entrypoint.sh §7) re-syncs THIS
# mounted workspace with `git nuke`, whose final step is
#   git submodule update --init --recursive --remote --rebase --force
# The `--remote` flag checks each submodule out to its REMOTE BRANCH TIP, NOT to
# the gitlink SHA the superproject pins. For a_solutions (cloud-u-containers, an
# SSH-url submodule this job has no deploy key for) that silently reverts the
# runner's correctly-checked-out pin to a stale commit (or a stale cached tip
# when the SSH fetch fails). consolidate/derive then reads OLD
# a_solutions/<svc>/build.json (CLOUD_ROOT/a_solutions is the worktree), so the
# regenerated dist matches the already-stale origin and the commit step reports
# "dist/ unchanged — nothing to commit". Net: config changes never deploy.
#
# Fix: force a_solutions back to the exact gitlink HEAD records, then ASSERT it.
# Failing loud here is strictly better than deriving stale config in silence.
_expected_sol="$(git -C "$REPO_ROOT" rev-parse HEAD:a_solutions 2>/dev/null || true)"
if [ -z "$_expected_sol" ]; then
  echo "::error::gen-configs: cannot read the a_solutions gitlink from HEAD — aborting" >&2
  exit 1
fi
git -C "$REPO_ROOT/a_solutions" checkout -q "$_expected_sol" 2>/dev/null \
  || git -C "$REPO_ROOT" -c protocol.file.allow=always submodule update --init --force -- a_solutions 2>/dev/null \
  || true
_actual_sol="$(git -C "$REPO_ROOT/a_solutions" rev-parse HEAD 2>/dev/null || true)"
if [ "$_actual_sol" != "$_expected_sol" ]; then
  echo "::error::gen-configs: a_solutions is at ${_actual_sol:-<none>} but the pin (HEAD:a_solutions) requires ${_expected_sol}." >&2
  echo "::error::  Refusing to derive STALE config. The builder's \`git nuke --remote\` re-checkout could not be corrected — the pinned commit is not present in the a_solutions object store (SSH fetch unavailable in this job)." >&2
  exit 1
fi
echo "── a_solutions pinned at ${_expected_sol} (matches gitlink; --remote drift corrected) ──"

echo "── Generating cloud-data + build-{name}.json ──"
bash build.sh config
echo "── Done. Generated files staged in dist/ — caller commits + pushes. ──"
