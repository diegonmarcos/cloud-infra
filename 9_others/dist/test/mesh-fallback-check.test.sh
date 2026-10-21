#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/mesh-fallback-check.test.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Guards #932's Linux ladder: the hosts lines the script prints are exactly the
# snapshot's pinned answers, and a snapshot without a bootstrap is a FAILURE (#368).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/1_cicd/src/scripts/cloud-mesh-fallback-check.sh"
SNAP="${MESH_SNAPSHOT:-$ROOT/1_cloud-configs/dist/mesh-snapshot.json}"
fail=0
bad() { echo "::error::$*"; fail=1; }

[ -s "$SNAP" ] || { echo "::error::$SNAP not found — this guard is unrun, not passing"; exit 1; }

want=$(jq -r '.bootstrap.pinned_hosts[] | .host as $h | (.v4[], .v6[]) | "\(.) \($h)"' "$SNAP" | sort)
got=$(MESH_SNAPSHOT="$SNAP" bash "$SCRIPT" hosts | sort)
[ -n "$want" ] || bad "snapshot pins no host"
[ "$want" = "$got" ] || bad "hosts lines differ from the snapshot's pinned answers"
# every pinned host must carry both families the zone declares (#519 AAAA twin)
jq -e '[.bootstrap.pinned_hosts[] | select((.v4|length)==0)] | length == 0' "$SNAP" >/dev/null || bad "a pinned host has no v4 answer"

# mutation: a snapshot with no bootstrap must exit 2, never pass
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
echo '{"bootstrap":{"pinned_hosts":[]}}' > "$tmp"
MESH_SNAPSHOT="$tmp" bash "$SCRIPT" hosts >/dev/null 2>&1; [ $? -eq 2 ] || bad "empty bootstrap did not fail"
MESH_SNAPSHOT=/nonexistent bash "$SCRIPT" hosts >/dev/null 2>&1; [ $? -eq 2 ] || bad "missing snapshot did not fail"
MESH_SNAPSHOT="$SNAP" bash "$SCRIPT" ssh-tunnel >/dev/null 2>&1; [ $? -eq 2 ] || bad "ssh-tunnel without a target did not fail"

[ $fail -eq 0 ] && echo "mesh-fallback-check: OK"
exit $fail
