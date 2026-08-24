#!/usr/bin/env bash
# Verifies prune_orphans in 1_cloud-configs/build.sh:
#   1. a build file declared in manifest.json survives
#   2. a build file absent from manifest.json is deleted, along with the
#      symlinks link-builds fanned into a_solutions/*/src/
#   3. an empty/garbage manifest prunes NOTHING (a failed run must not be
#      mistaken for "every build file is an orphan")
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD_SH="$REPO/1_cloud-configs/build.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "  ok   $1"
    else
        echo "  FAIL $1: expected '$2', got '$3'"
        fail=1
    fi
}

# Pull the function out rather than sourcing build.sh, which would run it.
sed -n '/^prune_orphans() {/,/^}/p' "$BUILD_SH" > "$TMP/fn.sh"
[ -s "$TMP/fn.sh" ] || { echo "FAIL: could not extract prune_orphans from build.sh"; exit 1; }

setup() { # setup <manifest-json>
    rm -rf "$TMP/work"
    # The sweep matches on links resolving into 1_cloud-configs/dist, so the
    # fixture has to reproduce that path shape.
    SCRIPT_DIR="$TMP/work/1_cloud-configs"
    DIST="$SCRIPT_DIR/dist"
    CLOUD_ROOT="$TMP/work"
    mkdir -p "$DIST" "$CLOUD_ROOT/a_solutions/infra-api_keeper/src"
    echo '{}' > "$DIST/build-keeper.json"
    echo '{}' > "$DIST/build-ghost.json"
    ln -s "$DIST/build-keeper.json" "$CLOUD_ROOT/a_solutions/infra-api_keeper/src/build-keeper.json"
    ln -s "$DIST/build-ghost.json"  "$CLOUD_ROOT/a_solutions/infra-api_keeper/src/build-ghost.json"
    # Already-dangling link from an earlier hand-deletion, and a dangling
    # link pointing somewhere other than dist/ (must be left alone).
    ln -s "$DIST/build-long-gone.json" "$CLOUD_ROOT/a_solutions/infra-api_keeper/src/build-long-gone.json"
    ln -s "/nonexistent/elsewhere.json" "$CLOUD_ROOT/a_solutions/infra-api_keeper/src/unrelated.json"
    # Archived solutions are frozen — dead links there are left as found.
    mkdir -p "$CLOUD_ROOT/a_solutions/z_archive/old-thing/src"
    ln -s "$DIST/build-archived.json" "$CLOUD_ROOT/a_solutions/z_archive/old-thing/src/build-archived.json"
    printf '%s\n' "$1" > "$SCRIPT_DIR/manifest.json"
    log() { :; }
    # shellcheck disable=SC1090
    . "$TMP/fn.sh"
}

echo "test: manifest declares only build-keeper.json"
setup '[{"file":"dist/build-keeper.json","name":"keeper"}]'
prune_orphans
check "declared file kept"       "yes" "$([ -e "$DIST/build-keeper.json" ] && echo yes || echo no)"
check "undeclared file pruned"   "yes" "$([ -e "$DIST/build-ghost.json" ] && echo no || echo yes)"
check "orphan symlink swept"     "yes" "$([ -L "$CLOUD_ROOT/a_solutions/infra-api_keeper/src/build-ghost.json" ] && echo no || echo yes)"
check "live symlink intact"      "yes" "$([ -L "$CLOUD_ROOT/a_solutions/infra-api_keeper/src/build-keeper.json" ] && echo yes || echo no)"
check "pre-existing dangling link swept" "yes" \
    "$([ -L "$CLOUD_ROOT/a_solutions/infra-api_keeper/src/build-long-gone.json" ] && echo no || echo yes)"
check "dangling link outside dist/ left alone" "yes" \
    "$([ -L "$CLOUD_ROOT/a_solutions/infra-api_keeper/src/unrelated.json" ] && echo yes || echo no)"
check "z_archive left frozen" "yes" \
    "$([ -L "$CLOUD_ROOT/a_solutions/z_archive/old-thing/src/build-archived.json" ] && echo yes || echo no)"

echo "test: manifest with no build-* entries prunes nothing"
setup '[{"file":"dist/mcp.json","name":"mcp"}]'
prune_orphans
check "keeper survives empty manifest" "yes" "$([ -e "$DIST/build-keeper.json" ] && echo yes || echo no)"
check "ghost survives empty manifest"  "yes" "$([ -e "$DIST/build-ghost.json" ] && echo yes || echo no)"

echo "test: unreadable manifest prunes nothing"
setup 'not json at all'
prune_orphans
check "keeper survives bad manifest" "yes" "$([ -e "$DIST/build-keeper.json" ] && echo yes || echo no)"
check "ghost survives bad manifest"  "yes" "$([ -e "$DIST/build-ghost.json" ] && echo yes || echo no)"


# ── link_container_builds: the counterpart — creates what the flake declares ──
sed -n '/^link_container_builds() {/,/^}/p' "$BUILD_SH" > "$TMP/fn2.sh"
[ -s "$TMP/fn2.sh" ] || { echo "FAIL: could not extract link_container_builds"; exit 1; }

echo "test: flake.nix container refs are materialised as relative symlinks"
setup '[{"file":"dist/build-keeper.json","name":"keeper"}]'
mkdir -p "$CLOUD_ROOT/a_solutions/infra-api_keeper/src" \
         "$CLOUD_ROOT/a_solutions/z_archive/old-thing/src"
echo 'container = builtins.fromJSON (builtins.readFile ./build-keeper.json);' \
    > "$CLOUD_ROOT/a_solutions/infra-api_keeper/src/flake.nix"
# Declares a build file that dist/ does not have — must warn, not crash.
echo 'container = builtins.fromJSON (builtins.readFile ./build-nosuch.json);' \
    >> "$CLOUD_ROOT/a_solutions/infra-api_keeper/src/flake.nix"
# Archived solutions are frozen — no links created there either.
echo 'container = builtins.fromJSON (builtins.readFile ./build-keeper.json);' \
    > "$CLOUD_ROOT/a_solutions/z_archive/old-thing/src/flake.nix"
SOLUTIONS_DIR="$CLOUD_ROOT/a_solutions"
L="$CLOUD_ROOT/a_solutions/infra-api_keeper/src/build-keeper.json"
# setup's own link is absolute; drop it so the engine is what creates this one.
rm -f "$L"
# shellcheck disable=SC1090
. "$TMP/fn2.sh"
link_container_builds

check "declared ref linked"        "yes" "$([ -L "$L" ] && echo yes || echo no)"
check "link resolves"              "yes" "$([ -e "$L" ] && echo yes || echo no)"
# Note: a `case` pattern's ')' closes the enclosing $( ) early — compare with
# parameter expansion instead. An absolute link would break in the container,
# where the repo is mounted at a different prefix.
tgt="$(readlink "$L")"
check "link is relative"           "yes" "$([ "${tgt#/}" = "$tgt" ] && echo yes || echo no)"
check "ref absent from dist skipped" "yes" \
    "$([ -e "$CLOUD_ROOT/a_solutions/infra-api_keeper/src/build-nosuch.json" ] && echo no || echo yes)"
check "z_archive not linked"       "yes" \
    "$([ -e "$CLOUD_ROOT/a_solutions/z_archive/old-thing/src/build-keeper.json" ] && echo no || echo yes)"

# A dangling link left by a rename must be replaced, not skipped as "exists".
rm -f "$L"; ln -s "../../../1_cloud-configs/dist/build-gone.json" "$L"
link_container_builds
check "dangling ref repointed"     "yes" "$([ -e "$L" ] && echo yes || echo no)"

[ "$fail" -eq 0 ] && echo "PASS" || echo "FAILED"
exit "$fail"
