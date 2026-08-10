#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/scripts/cloud-ship-orchestrate-gen-configs.sh
# ║   Engine : 1_configs/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ── Generate per-container build-{name}.json + cloud-data-{name}.json ──
#
# Runs `bash build.sh config` to regenerate dist/ from a_solutions/*/build.json.
# The regenerated files are committed by the standard ci flow (the workflow
# caller commits + pushes), not from inside this script.
#
# 2026-04-27: removed the previous `cd 1_configs/dist && git push` block. It
# assumed 1_configs/dist/ was the cloud-data submodule — it is NOT (it is a
# regular subdir of the cloud repo). The push was either a no-op (no changes)
# or hit the cloud repo's own origin. The cloud-data submodule (I_cloud-data/)
# is now frozen — every container reads its own build-{containername}.json.
#
# Usage: ship-gen-configs.sh
set -euo pipefail

REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT"
export GIT_BASE="${GIT_BASE:-$(dirname "$REPO_ROOT")}"

echo "── Generating cloud-data + build-{name}.json ──"
bash build.sh config
echo "── Done. Generated files staged in dist/ — caller commits + pushes. ──"
