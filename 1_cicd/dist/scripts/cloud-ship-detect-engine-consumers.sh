#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_cicd/src/scripts/cloud-ship-detect-engine-consumers.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ── Which services does a change to _shared/ (the shared container engine) ship? ──
#
# Reverse-walks a_solutions/*/src for the declaration that ALREADY names the
# dependency -- each service's flake reads `import ../../_shared/engine.nix` --
# and emits every service whose source actually references the shared engine.
#
# WHY this is a script and not more shell inline in ship.yml's detect step: it
# decides whether the widest-blast-radius change in the repository -- a change
# to the engine every container service is built with -- ships any service at
# all. Before this, `_shared/engine.nix` had first segment `_shared` and a
# remainder matching neither branch of the first-segment classifier
# `^[^/]+/(src/|build\.json$)`, so an engine-only commit resolved to ZERO
# services and the run concluded green having built nothing (#451). Like the
# dist-consumer detection before it, this ships (or silently fails to ship)
# services across the whole fleet, so it must be drivable with synthetic input
# to prove both directions -- 9_others/test/test_detect_engine_consumers.sh
# does exactly that.
#
# Usage: cloud-ship-detect-engine-consumers.sh < <changed-paths>
#   cwd (or any parent) must be the cloud-infra checkout, with a_solutions/
#   populated (a_solutions is the cloud-u-containers checkout at the path every
#   in-repo reference already uses).
#   stdin: one a_solutions-relative changed path per line (ship.yml's
#          $SUB_CHANGED verbatim).
#   stdout: ONE line, the space-separated engine-consumer service dirs to ship
#           (EMPTY when no changed path is under _shared/).
#   stderr: reasoning -- the consumer set and the declaration that resolved it.
#
# The fan-out is DERIVED, never hardcoded: a build.json service that does not
# import the engine (e.g. a front-end with its own build) is NOT a consumer and
# must not ship, or every engine work-item would rebuild the whole fleet
# (#146/#235/#248/#263). Only services whose src/ references `_shared/engine.nix`
# ship.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT" || exit 1

# ── Is there a _shared/ change at all? ───────────────────────────────────────
# No engine change -> no engine fan-out. Faster and, more importantly, the
# fan-out must NEVER fire on a push that did not touch the engine.
ENGINE_CHANGED=""
while IFS= read -r _p; do
  case "$_p" in
    _shared/*) ENGINE_CHANGED=1 ;;
  esac
done
[ -n "$ENGINE_CHANGED" ] || exit 0

# ── Resolve the consumer set from the declarations ───────────────────────────
# Same shape as the dist-consumer index: walk each service's src for the literal
# that names the dependency and take the owning service dir (field 2 of
# a_solutions/<svc>/src/...). The engine is consumed through src (flake.nix and
# the compose files it drives); generated dist/ output and node_modules are not
# declarations of consumption and are excluded, as are archived services (they
# have no deploy target).
CONSUMERS=""
if [ -d a_solutions ]; then
  CONSUMERS=$(grep -rl --include='*.nix' \
        --exclude-dir=dist --exclude-dir=node_modules --exclude-dir=.git \
        '_shared/engine.nix' a_solutions/*/src 2>/dev/null \
      | awk -F/ '$2 != "z_archive" && $2 != "_shared" {print $2}' \
      | sort -u | tr '\n' ' ')
fi

if [ -z "$CONSUMERS" ]; then
  # Found the engine change but resolved zero consumers: either the a_solutions
  # checkout is absent, or no service's declaration references the engine. Both
  # are the fail-open direction a hollow green must not mask -- say so out loud.
  echo "::warning::detect: a change under _shared/ resolved to ZERO engine consumers -- is a_solutions/ populated and does any service's src import the shared engine?" >&2
fi

[ -z "$CONSUMERS" ] || echo "::notice::shared-engine consumers: $CONSUMERS" >&2
printf '%s' "$CONSUMERS"