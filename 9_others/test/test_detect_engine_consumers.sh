#!/usr/bin/env bash
# Test: cloud-ship-detect-engine-consumers.sh ships the shared engine's
# consumers, and only them.
#
# #451: `_shared/engine.nix` has first segment `_shared` and remainder
# `engine.nix`, so the first-segment classifier `^[^/]+/(src/|build\.json$)`
# maps it to NO service. An engine-only commit therefore resolved to ZERO
# services, the Ship run concluded green, and nothing was built — the
# widest-blast-radius change in the repository was the one change the detector
# could not see.
#
# The fix derives the fan-out from the declaration that ALREADY names the
# dependency: each service's src/flake.nix reads `import ../../_shared/engine.nix`.
# The assertion with value here is that BOTH directions hold on real git
# history built into a throwaway repo laid out like the fleet: an engine change
# ships the consumer and only the consumer, and a change that does not touch
# the engine ships nothing. Getting the first wrong ships a green run that
# deployed nothing; getting the second wrong rebuilds the fleet on every push
# (#146/#235/#248/#263).
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DETECT="$REPO_ROOT/1_cicd/src/scripts/cloud-ship-detect-engine-consumers.sh"
[ -f "$DETECT" ] || { echo "::error::$DETECT not found"; exit 1; }

FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT
FAILED=0

# ── A fleet-shaped fixture ──────────────────────────────────────────────────
# engine_svc: imports ../../_shared/engine.nix (a real consumer)
# quiet_svc:  has build.json + src but NEVER imports the engine (a real
#             non-consumer that must not ship — the over-trigger case)
build_fixture() {
  rm -rf "$FIXTURE"; mkdir -p "$FIXTURE"
  cd "$FIXTURE"
  git init -q .
  git config user.email t@t; git config user.name t

  # a_solutions IS the cloud-u-containers checkout at the path ship.yml's
  # detect step already uses; services (and the shared engine) live under it.
  mkdir -p a_solutions/_shared
  cat > a_solutions/_shared/engine.nix <<'NIX'
{ lib }:
{ engineMarker = "shared"; inherit = lib; }
NIX
  for svc in engine_svc quiet_svc; do mkdir -p "a_solutions/$svc/src"; done
  cat > a_solutions/engine_svc/src/flake.nix <<'NIX'
{
  engine = import ../../_shared/engine.nix;
  outputs = { inherit = engine; };
}
NIX
  cat > a_solutions/quiet_svc/src/flake.nix <<'NIX'
{ lib }:
{ own = "no shared engine here"; }
NIX

  git add -A >/dev/null; git commit -qm base
  cd - >/dev/null
}

# Run the detector over the given changed-path line; stdout only.
resolve() {  # $1 = a_solutions-relative changed path(s), one per line
  local r
  r=$(cd "$FIXTURE" && printf '%s\n' "$1" | bash "$DETECT" 2>/dev/null)
  printf '%s' "${r% }"   # trim the trailing space tr emits, as the ship.yml caller does
}

check() {  # $1 = label   $2 = expected   $3 = actual
  if [ "$3" = "$2" ]; then
    echo "  ok   $1 → '$3'"
  else
    echo "::error::$1 — expected '$2', got '${3:-<empty>}'"
    FAILED=1
  fi
}

# ── 1. Engine-only change → the consumer ships, the non-consumer does not ────
build_fixture
RES=$(resolve $'_shared/engine.nix\n_shared/docker.nix\n')
check "engine change resolves the importing consumer" "engine_svc" "$RES"
case " $RES " in
  *" quiet_svc "*) echo "::error::engine change dragged in a non-consumer (over-trigger)"; FAILED=1 ;;
  *)                echo "  ok   engine change excludes the non-consumer (no over-trigger)" ;;
esac

# ── 2. A change that does NOT touch the engine → nothing ships ──────────────
RES=$(resolve $'quiet_svc/src/flake.nix\nengine_svc/build.json\n')
check "non-engine change ships nothing" "" "$RES"

# ── 3. Empty / absent change set → nothing ships ────────────────────────────
RES=$(resolve '')
check "empty change set ships nothing" "" "$RES"

# ── 4. The BEFORE direction is locked in: the old first-segment classifier ──
# The historical defect was that the regex alone left `_shared/engine.nix` at
# zero services. Replay that exact classifier to prove the regression the walk
# closes: if this ever starts resolving `_shared/`, the fix was reverted to a
# naive regex and the walk is dead weight.
OLD_RE='^[^/]+/(src/|build\.json$)'
OLD=$(printf '%s\n' '_shared/engine.nix' | grep -E "$OLD_RE" | awk -F/ '{print $1}' | sort -u | tr '\n' ' ')
check "old regex still resolves _shared/engine.nix to NOTHING (mutation)" "" "$OLD"

# ── 5. stdout is the caller's contract: exactly the services to ship ────────
# ship.yml assigns this verbatim into an append; a reason line leaking to
# stdout would put a sentence where a service dir belongs.
build_fixture
OUT=$(resolve $'_shared/compose-defaults.json\n')
if [ "$OUT" = "engine_svc" ] || [ "$OUT" = "engine_svc " ]; then
  echo "  ok   stdout carries only the ship list → '$OUT'"
else
  echo "::error::stdout contract — expected just 'engine_svc', got '$OUT'"
  FAILED=1
fi

[ "$FAILED" -eq 0 ] || exit 1
echo "PASS: engine-consumer detection ships the shared engine's consumers, and only them"