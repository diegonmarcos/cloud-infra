#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/deploy/test/test_container_name_matches_declaration.sh
# ║   Engine : 1_configs/src/deploy/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 11 tester — container_name in compose matches build.json   ║
# ║                                                                  ║
# ║ Proves:                                                          ║
# ║   Every docker-compose.yml `services.<svc>.container_name`       ║
# ║   matches a `build.json.containers.<any>.container_name` for     ║
# ║   the same service directory. Without this, the drift detector  ║
# ║   (which matches by literal container_name) flags perfectly-     ║
# ║   healthy containers as "unmanaged" because docker-compose's     ║
# ║   auto-naming <project>_<svc>_1 drifts from the declaration.    ║
# ║                                                                  ║
# ║   Root-cause of cloud-builder-x-cloud-builder-1 drift noise in   ║
# ║   health-full-2 report (2026-04-21 triage, H2).                  ║
# ║                                                                  ║
# ║ Also validates: every service with `on_demand: true` has this    ║
# ║ flag recognised in the schema (future: health reports honour it).║
# ║                                                                  ║
# ║ Usage: bash 1_configs/src/deploy/test/test_container_name_matches_declaration.sh
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── 1: on_demand field declared in schema ──"

schema="$REPO_ROOT/a_solutions/build.schema.json"
if jq -e '.properties.on_demand.type == "boolean"' "$schema" >/dev/null 2>&1; then
    pass "build.schema.json declares on_demand: boolean"
else
    fail "build.schema.json missing on_demand field"
fi

echo ""
echo "── 2: cloud-builder-x uses explicit container_name + on_demand ──"

cb_build="$REPO_ROOT/a_solutions/infra-bld_cloud-builder-x/build.json"
if jq -e '.on_demand == true' "$cb_build" >/dev/null 2>&1; then
    pass "bd-cloud-builder-x has on_demand: true"
else
    fail "bd-cloud-builder-x missing on_demand: true"
fi

# Follow the src symlink into unix submodule for the compose source
cb_compose="$REPO_ROOT/a_solutions/infra-bld_cloud-builder-x/src/docker/compose.yaml"
if [ -f "$cb_compose" ]; then
    if grep -qE '^\s+container_name:\s*cloud-builder-x\s*$' "$cb_compose"; then
        pass "cloud-builder compose declares container_name: cloud-builder-x"
    else
        fail "compose.yaml does not explicitly set container_name: cloud-builder-x (docker will auto-name as cloud-builder-x-cloud-builder-1 → drift)"
    fi
else
    echo "  • compose source not checked out (submodule) — skipping compose.yaml assertion"
fi

echo ""
echo "── 3: every service with a custom container_name in compose has a matching build.json decl ──"

for compose in "$REPO_ROOT"/a_solutions/*/dist/docker-compose.yml; do
    [ -f "$compose" ] || continue
    svc_dir=$(basename "$(dirname "$(dirname "$compose")")")
    bj="$REPO_ROOT/a_solutions/$svc_dir/build.json"
    [ -f "$bj" ] || continue
    # Extract every container_name from the compose
    while read -r cname; do
        [ -n "$cname" ] || continue
        # Assert build.json containers[*].container_name contains it
        if jq -e --arg n "$cname" '.containers // {} | to_entries[] | select(.value.container_name == $n)' "$bj" >/dev/null 2>&1; then
            : # match — silent
        else
            # Relax: also allow top-level .name match (single-container services)
            if [ "$(jq -r '.name' "$bj")" = "$cname" ]; then
                : # ok
            else
                fail "$svc_dir: compose.yml declares container_name=$cname but build.json has no matching containers.*.container_name"
            fi
        fi
    done < <(grep -E '^\s+container_name:\s+' "$compose" | awk '{print $2}' | sort -u)
done

# If we got here with no failures from the loop
if [ "$FAIL" -eq 0 ]; then
    pass "every compose container_name matches a build.json declaration"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "══════════════════════════════════════════════"
    echo "Phase 11 container_name vs declaration: PASS"
    echo "══════════════════════════════════════════════"
    exit 0
else
    echo "══════════════════════════════════════════════"
    echo "Phase 11 container_name vs declaration: FAIL"
    echo "══════════════════════════════════════════════"
    exit 1
fi
