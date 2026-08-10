#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/test/test_step_docker_uses_cache.sh
# ║   Engine : 1_configs/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Test: step_docker uses --cache-from layer-cache strategy on BOTH the
# `local` (GHA host) and `ssh` (oci-apps cloud-builder-x) branches.
#
# Without this, every push pays a full rebuild. The strategy: pull the
# previously-published GHCR image and pass it as --cache-from; Docker
# reuses identical layers. `docker pull ... || true` tolerates the
# first-ever build cold-cache. Self-bootstraps from the second build.
#
# This tester also enforces the absence of `--no-cache` (the prior
# wholesale-rebuild behaviour) — keeping it would silently override the
# new --cache-from flags.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
ENGINE="$REPO_ROOT/1_configs/src/scripts/cloud-ship-container-step-build-docker.sh"

[ -f "$ENGINE" ] || { echo "::error::$ENGINE not found"; exit 1; }

FAIL=0

# 1) Both branches must include `docker pull ... || true`
PULL_COUNT=$(grep -cE 'docker pull.*\|\|[[:space:]]*true' "$ENGINE" || true)
if [ "$PULL_COUNT" -ge 4 ]; then
    printf "  OK  step_docker pulls FULL_IMAGE + BINARIES_IMAGE in both local + ssh branches (%d pulls)\n" "$PULL_COUNT"
else
    printf "  FAIL step_docker should pull existing image (with || true) before build — found %d, expected >= 4\n" "$PULL_COUNT"
    FAIL=1
fi

# 2) Both branches must use --cache-from
CF_COUNT=$(grep -cE -- '--cache-from' "$ENGINE" || true)
if [ "$CF_COUNT" -ge 4 ]; then
    printf "  OK  step_docker uses --cache-from for FULL_IMAGE + BINARIES_IMAGE in both branches (%d flags)\n" "$CF_COUNT"
else
    printf "  FAIL step_docker should use --cache-from (FULL + BINARIES in local + ssh) — found %d, expected >= 4\n" "$CF_COUNT"
    FAIL=1
fi

# 3) --no-cache must NOT appear on the docker build invocations.
#    (We allow the word elsewhere, e.g. in comments — match the build line itself.)
if grep -E 'docker build.*--no-cache' "$ENGINE" >/dev/null 2>&1; then
    printf "  FAIL --no-cache still on a docker build line — would override --cache-from\n"
    grep -nE 'docker build.*--no-cache' "$ENGINE" | sed 's/^/    /'
    FAIL=1
else
    printf "  OK  no --no-cache on any docker build invocation\n"
fi

if [ "$FAIL" -eq 1 ]; then
    echo
    echo "::error::step_docker layer-cache regression"
    exit 1
fi

echo
echo "step_docker uses --cache-from layer-cache strategy on both runner branches."
