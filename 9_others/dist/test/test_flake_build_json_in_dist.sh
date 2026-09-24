#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_flake_build_json_in_dist.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# #564 — every live service's per-container config must be one dist/ still emits.
#
# cloud-infra's derive step writes each container's config as
# 1_cloud-configs/dist/build-<container_name>.json, and every service flake pins
# it with `container = builtins.fromJSON (builtins.readFile ./build-<X>.json)`.
# So a container RENAME silently moves a generated filename out from under the
# flake. #542 (cloud-agi-*) did exactly that to three services:
#   · my-ai_claude-api — symlink, target gone. Build → oci-apps failed in Ship
#     35992310672, and with it every deploy on all four VMs that run.
#   · hermes-agent     — symlink, target gone. Latent until hermes next shipped.
#   · my-ai-api        — a REGULAR FILE (52,827 B) whose dist name was gone. It
#     kept building from frozen pre-rename config and could never fail.
# Nothing caught any of it: Phase 4 (test_build_container_json_pattern.sh) only
# looks at symlinks, and lint-pipeline only runs on cloud-infra pushes, never on
# the cloud-u-containers push that carries a rename. This runs in the Ship
# detect job too (ship.yml "Guard" step), so it fires on every containers-push.
#
# Contract, for every service registered in build-gha.json (the live set — read,
# never restated):
#   1. each `readFile ./build-*.json` in src/flake.nix exists in src/, and
#      · a symlink into 1_cloud-configs/dist must name a file dist/ contains;
#      · a regular file must carry a name dist/ still emits (else it is a frozen
#        copy of a container that no longer exists under that name) — one that
#        does is still a drift risk and is WARNED, not failed (conversion is its
#        own ticket);
#   2. every other build-*.json SYMLINK in src/ into dist/ names a file dist/
#      contains (a dangling link is fatal to the builder's COPY and to nix).
# Symlink targets are compared by BASENAME against the dist listing, so this
# gives the same verdict in the builder layout and on a sibling checkout.
#
# Inputs (env, for exercising the guard against another tree):
#   A_SOLUTIONS  default $REPO_ROOT/a_solutions
#   DIST         default $REPO_ROOT/1_cloud-configs/dist
set -u

REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
A_SOLUTIONS="${A_SOLUTIONS:-$REPO_ROOT/a_solutions}"
DIST="${DIST:-$REPO_ROOT/1_cloud-configs/dist}"
GHA="$DIST/build-gha.json"

# A guard that cannot reach its subject FAILS — never passes vacuously.
[ -f "$GHA" ] || { echo "::error::$GHA missing — cannot read the live service set"; exit 1; }
[ -d "$A_SOLUTIONS" ] || { echo "::error::$A_SOLUTIONS missing — cloud-u-containers not checked out, nothing verified"; exit 1; }

fail=0; flakes=0; refs=0; links=0; frozen=0
bad() { echo "::error::$1"; fail=$((fail + 1)); }

# dist_name <link> — basename of the dist file a symlink targets, empty if the
# link does not point into 1_cloud-configs/dist at all (intra-service link).
dist_name() { case "$(readlink "$1")" in */1_cloud-configs/dist/*) basename "$(readlink "$1")" ;; esac; }

for dir in $(jq -r '.services[].dir' "$GHA" | sort -u); do
    src="$A_SOLUTIONS/$dir/src"
    [ -d "$src" ] || continue
    flake="$src/flake.nix"
    if [ -f "$flake" ]; then
        flakes=$((flakes + 1))
        for ref in $(grep -oE 'readFile \./build-[A-Za-z0-9_.-]+\.json' "$flake" | sed 's|readFile \./||' | sort -u); do
            refs=$((refs + 1))
            f="$src/$ref"
            if [ -L "$f" ]; then
                n="$(dist_name "$f")"
                if [ -n "$n" ]; then
                    [ -f "$DIST/$n" ] || bad "$dir/src/flake.nix reads $ref -> dist/$n, which dist/ no longer emits (container renamed?). Retarget the link to the current build-<container_name>.json."
                else
                    [ -e "$f" ] || bad "$dir/src/flake.nix reads $ref, a dangling intra-service symlink"
                fi
            elif [ -f "$f" ]; then
                if [ -f "$DIST/$ref" ]; then
                    frozen=$((frozen + 1))
                    echo "::warning::$dir/src/$ref is a REGULAR FILE copy of dist/$ref — it builds from a frozen snapshot that drifts silently; convert it to a symlink"
                else
                    bad "$dir/src/flake.nix reads $ref, a REGULAR FILE whose name dist/ no longer emits — the container builds from frozen config of a renamed/removed container and cannot fail on its own"
                fi
            else
                bad "$dir/src/flake.nix reads $ref, which does not exist in src/"
            fi
        done
    fi
    for f in "$src"/build-*.json; do
        [ -L "$f" ] || continue
        n="$(dist_name "$f")"
        [ -n "$n" ] || continue
        links=$((links + 1))
        [ -f "$DIST/$n" ] || bad "$dir/src/$(basename "$f") -> dist/$n, which dist/ no longer emits"
    done
done

# Vacuity guard: a walk that read no flake refs verified nothing.
[ "$refs" -gt 0 ] || bad "read 0 flake readFile ./build-*.json refs across $flakes flakes — the walk verified nothing"

echo "flakes=$flakes refs=$refs dist-links=$links frozen-copies=$frozen failures=$fail"
[ "$fail" -eq 0 ]
