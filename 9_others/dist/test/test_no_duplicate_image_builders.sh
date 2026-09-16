#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_no_duplicate_image_builders.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Test: no GHA workflow uses docker/build-push-action — step_docker (the
# universal engine in cloud-ship-container-step-build-docker.sh) MUST be
# the sole image builder. Stack philosophy rule 2: "BUILD AND CI/CD ONLY
# DONE BY UNIVERSAL ENGINES".
#
# Catches the regression where ship-ghcr-images.yml ran a parallel build
# matrix that duplicated step_docker's work, raced on the :latest tag, and
# never produced the -binaries:latest tag that compose layers need
# (forcing a second rebuild on the next ship anyway).
set -eu

# Repo root by upward search, not a fixed ../../.. — this file exists at BOTH
# 9_others/test/ and 1_cicd/dist/test/ (generated), which sit at
# different depths, so one literal count is wrong for one of the two copies.
REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
CICD_DIR="$REPO_ROOT/1_cicd/src/cicd"

[ -d "$CICD_DIR" ] || { echo "::error::$CICD_DIR not found"; exit 1; }

OFFENDERS=""
for f in "$CICD_DIR"/*.yml; do
    [ -f "$f" ] || continue
    if grep -qE 'uses:[[:space:]]+docker/build-push-action' "$f"; then
        OFFENDERS="$OFFENDERS $(basename "$f")"
    fi
done

if [ -n "$OFFENDERS" ]; then
    echo "::error::Workflows using docker/build-push-action (forbidden — step_docker owns image builds):"
    for o in $OFFENDERS; do echo "  - $o"; done
    echo
    echo "Fix: route the build through cloud-ship-container-step-build-docker.sh"
    echo "(via ship.yml matrix or per-service build.sh) — it pushes both"
    echo "<image>:latest AND <image>-binaries:latest, the latter required by"
    echo "every service's compose.yaml. docker/build-push-action only pushes"
    echo "the former, so compose-pull on the VM fails with 'denied: denied'."
    exit 1
fi

echo "No workflow uses docker/build-push-action — step_docker is the sole image builder."
