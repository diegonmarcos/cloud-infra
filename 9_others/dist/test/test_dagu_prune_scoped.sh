#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_dagu_prune_scoped.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Test: no dagu DAG runs an unscoped docker prune (#353, #393, #396).
#
# ops_docker-prune ran `docker system prune -af` every 3 days on every VM and
# deleted umami (and matomo) outright: the load-shedder stops containers, the
# sweep removed the stopped container and then its now-unreferenced image.
# The DAG is scoped today; this keeps it that way.
#
# Scans both trees:
#   a_solutions/infra-obs_dagu/src/dags — the source
#   the dir compose.nix mounts at DAGU_DAGS_DIR (read from compose.nix, not
#   assumed) resolved under ../dist — what is actually deployed to oci-apps.
#
# An EXECUTED prune is a non-comment line with `docker <x> prune` that runs it:
# over $SSH, at line start, or after && / ; / |. Advice text inside an echo
# (ops_capacity-review) is not executed and not matched.
#
# Rules on every executed prune:
#   no `docker system prune`   — superset sweep, the #353 command
#   no `docker volume prune`   — volumes hold the databases
#   no `docker image prune -a` — -a drops TAGGED images, i.e. declared ones
#   `docker container prune` must filter label!=com.docker.compose.project
# Floor: each tree must contain at least one executed prune, so a renamed DAG
# or a broken pattern goes RED instead of passing on nothing.
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/a_solutions/infra-obs_dagu/src"
[ -f "$HERE/compose.nix" ] || { echo "FAIL: $HERE not checked out (a_solutions = cloud-u-containers)"; exit 1; }
fails=0
nope() { echo "FAIL: $*"; fails=$((fails + 1)); }

mount_src=$(sed -n 's|.*"\(\./[^":]*\):/var/lib/dagu/dags".*|\1|p' "$HERE/compose.nix" | head -1)
[ -n "$mount_src" ] || { echo "FAIL: compose.nix mounts nothing at /var/lib/dagu/dags"; exit 1; }
DEPLOYED="$HERE/../dist/${mount_src#./}"

for tree in "$HERE/dags" "$DEPLOYED"; do
    [ -d "$tree" ] || { nope "$tree missing"; continue; }
    lines=$(grep -Hn 'docker [a-z]* *prune' "$tree"/*.yaml \
        | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*#' \
        | grep -E '\$SSH|^[^:]+:[0-9]+:[[:space:]]*docker |(&&|;|\|)[[:space:]]*docker ' || true)
    n=$(printf '%s' "$lines" | grep -c . || true)
    [ "$n" -gt 0 ] || nope "$tree: no executed docker prune found — pattern or DAG moved"
    echo "$tree: $n executed prune line(s)"

    printf '%s\n' "$lines" | grep -q 'docker system prune' && nope "$tree: docker system prune"
    printf '%s\n' "$lines" | grep -q 'docker volume prune' && nope "$tree: docker volume prune"
    printf '%s\n' "$lines" | grep -Eq 'docker image prune[^"&;|]* (-a|-af|-fa|--all)( |=|"|$)' \
        && nope "$tree: docker image prune -a"
    printf '%s\n' "$lines" | grep 'docker container prune' \
        | grep -qv 'container prune[^"&;|]*--filter label!=com.docker.compose.project' \
        && nope "$tree: docker container prune without the compose-label filter"
done

[ "$fails" -eq 0 ] || { echo "RED: $fails violation(s)"; exit 1; }
echo "GREEN: every executed prune in src and deployed DAGs is scoped"
