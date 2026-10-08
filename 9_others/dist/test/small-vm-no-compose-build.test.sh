#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/small-vm-no-compose-build.test.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Guard: the ship engine must NEVER emit a `docker compose` command that the
# small-VM docker wrapper refuses.
#
# The wrapper (~/.local/bin/docker on the sub-2GB VMs — measured on oci-mail
# 10.0.0.3 and oci-analytics 10.0.0.4, both 954MB) refuses exactly three things:
#   * `docker build`            (argv[1])
#   * `docker buildx`           (argv[1])
#   * `docker compose ... --build`  (any argv equal to the literal --build)
# and reports the refusal on STDERR as "BLOCKED: docker ... on a small VM",
# exit 1. We assert on that MESSAGE substring, not on an exit status, because
# an exit status is indistinguishable from any other compose failure.
#
# WHY THIS GUARD AND NOT A build.json ONE (#650):
# build.json's `deploy.compose_flags` is INERT. In the deployed engine the value
# is read once and then only grepped for `--build` to log a warning; it is never
# spliced into the remote command. The real command is built independently as
#   COMPOSE_UP_FLAGS="--no-build $_PULL_POLICY $_RECREATE"
# So a tester that asserted `compose_flags` against the wrapper's refusal list
# would be asserting a field with no production consequence — green that
# verifies nothing. The property that actually keeps the 1GB VMs alive is that
# the ENGINE always emits --no-build and never interpolates compose_flags into a
# command. That is what is asserted here.
#
# Both src/ and dist/ are checked: the engine RUNS from dist/, so a src-only fix
# is inert, and a dist-only fix is erased by the next recompile.
set -eu

fail() { echo "FAIL: $1" >&2; exit 1; }

ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}"

# Overridable so mutation-testing can point the guard at a doctored copy
# without touching the tracked files.
SRC="${DEPLOY_COMPOSE_SRC:-$ROOT/1_cicd/src/scripts/cloud-ship-container-step-deploy-compose.sh}"
DIST="${DEPLOY_COMPOSE_DIST:-$ROOT/1_cicd/dist/scripts/cloud-ship-container-step-deploy-compose.sh}"

# The wrapper's refusal message, as emitted by the deployed wrapper.
WRAPPER_REFUSAL='BLOCKED: docker %s on a small VM'

check_file() {
    _label="$1"; _f="$2"
    [ -f "$_f" ] || fail "$_label: engine script not found at $_f"

    # 1. The up-flags must be initialised WITH --no-build. This is the single
    #    assertion that keeps `compose --build` from ever reaching the wrapper.
    if ! grep -Eq '^[[:space:]]*COMPOSE_UP_FLAGS="--no-build[[:space:]]' "$_f"; then
        fail "$_label: COMPOSE_UP_FLAGS is not initialised with --no-build — a deploy to a sub-2GB VM would be refused by the wrapper: $(printf "$WRAPPER_REFUSAL" 'compose --build')"
    fi

    # 2. build.json's compose_flags must never be interpolated into a command.
    #    It is advisory only; splicing it back in would re-expose every service
    #    that still declares --build (11 of them at the time of writing).
    if grep -n 'docker compose' "$_f" | grep -q '\$COMPOSE_FLAGS\|\${COMPOSE_FLAGS'; then
        fail "$_label: \$COMPOSE_FLAGS is spliced into a 'docker compose' command — build.json declarations would reach the wrapper: $(printf "$WRAPPER_REFUSAL" 'compose --build')"
    fi

    # 3. No emitted compose command may carry a bare --build token, however it
    #    got there (hardcoded, or via any other variable).
    if grep 'docker compose' "$_f" | grep -Eq '(^|[[:space:]])--build([[:space:]]|"|$)'; then
        fail "$_label: a 'docker compose' command carries --build: $(printf "$WRAPPER_REFUSAL" 'compose --build')"
    fi

    # 4. The engine must not shell out to `docker build`/`buildx` on a deploy
    #    host either — same wrapper, same refusal.
    if grep -Eq '(^|[^-[:alnum:]])docker[[:space:]]+(build|buildx)([[:space:]]|$)' "$_f"; then
        fail "$_label: engine invokes 'docker build'/'buildx' on the deploy host: $(printf "$WRAPPER_REFUSAL" 'build')"
    fi
}

check_file src  "$SRC"
check_file dist "$DIST"

# 5. src and dist must agree on the up-flags line. A divergence means the
#    compiled engine is not the reviewed one (the ship runs dist/).
_s=$(grep -E '^[[:space:]]*COMPOSE_UP_FLAGS=' "$SRC" | head -1 | tr -d '[:space:]')
_d=$(grep -E '^[[:space:]]*COMPOSE_UP_FLAGS=' "$DIST" | head -1 | tr -d '[:space:]')
[ -n "$_s" ] || fail "src: no COMPOSE_UP_FLAGS assignment found"
[ "$_s" = "$_d" ] || fail "src/dist COMPOSE_UP_FLAGS diverge — dist is what ships: src=[$_s] dist=[$_d]"

echo "PASS: engine emits --no-build (src+dist agree); compose_flags never spliced; no docker build on deploy hosts"
