#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_workflows/src/test/test_docker_compose_no_build.sh
# ║   Engine : 1_workflows/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# test_docker_compose_no_build.sh — lint that catches `docker compose up`
# invocations missing --no-build.
#
# Policy: every container image is pre-built and pushed to GHCR. VMs only
# pull, never build. Therefore every `docker compose up` in this repo
# (engines + per-service manage scripts) MUST include --no-build.
#
# This test exits 1 if any source script invokes `docker compose up`
# without --no-build on the same line. Comments, docs, archived dirs,
# shell aliases, and the no-build-guard wrappers themselves are
# excluded.
#
# Source: 1_workflows/src/test/test_docker_compose_no_build.sh
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PASS=0; FAIL=0
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }

# Find every line that invokes `docker compose up` (or `docker-compose up`)
# under repo source and is NOT inside an excluded path.
mapfile -t HITS < <(
  grep -rn -E 'docker[[:space:]-]compose up( |$)' "$REPO_ROOT" \
    --include='*.sh' --include='*.nix' --include='*.yml' --include='*.yaml' \
    --exclude-dir='.git' \
    --exclude-dir='dist' \
    --exclude-dir='z_archive' \
    --exclude-dir='_archive' \
    --exclude-dir='node_modules' \
    --exclude-dir='III_unix' \
    --exclude-dir='II_tools' \
    --exclude-dir='d_myhardware' \
    2>/dev/null \
  | grep -v -E '(no-build-guard|guardrails|claude-memory|pretool-guard|declarative-guard)' \
  | grep -v -E '^\s*#' \
  | grep -v -E '^\s*//' \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
  | grep -vE 'echo[[:space:]]' \
  | grep -vE 'printf[[:space:]]' \
  | grep -vE '(^|[^a-z_])log[[:space:]]+["'"'"']'

)

VIOLATIONS=""
for line in "${HITS[@]}"; do
  # The line literally contains `docker compose up` (or hyphenated). It's a
  # violation only if --no-build is NOT also on that line.
  if echo "$line" | grep -qE -- '--no-build|--no-rebuild'; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    VIOLATIONS+="${line}"$'\n'
  fi
done

printf "\n──────────────────────────────────\n"
printf "docker compose up audit\n"
printf "──────────────────────────────────\n"
if [ "$FAIL" -eq 0 ]; then
  green "✓ all $PASS invocations include --no-build (or --no-rebuild)"
else
  red "✗ $FAIL violation(s) found (no --no-build on the same line):"
  printf '%s' "$VIOLATIONS" | sed 's|^|  |'
  green "  $PASS invocation(s) correctly use --no-build"
fi

[ "$FAIL" -eq 0 ]
