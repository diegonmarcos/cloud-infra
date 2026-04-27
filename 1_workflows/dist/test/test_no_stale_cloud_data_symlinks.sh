#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_workflows/src/test/test_no_stale_cloud_data_symlinks.sh
# ║   Engine : 1_workflows/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 31 tester — no per-domain cloud-data-*.json refs in        ║
# ║ a_solutions/*/src/ (retired class).                              ║
# ║                                                                   ║
# ║ Failure mode this catches (proven 2026-04-27 lint-pipeline runs   ║
# ║ 25009309581 + 25009587333 + 25009822313): 61 tracked symlinks    ║
# ║ in a_solutions/*/src/cloud-data-*.json → ../../../2_configs/     ║
# ║ dist/cloud-data-*.json. Targets were gen-configs output, never   ║
# ║ committed → broken symlinks → lint-pipeline preflight aborts.    ║
# ║                                                                   ║
# ║ The cloud-data-*.json class is RETIRED. Services now read either ║
# ║ per-service build-{name}.json (port/image/deploy config) or      ║
# ║ _cloud-data-consolidated.json (single bundled topology). Per-    ║
# ║ domain cloud-data-*.json files are no longer produced and must   ║
# ║ not be referenced from a_solutions/*/src/.                       ║
# ║                                                                   ║
# ║ Phase 31 fails if any tracked file path matches:                 ║
# ║     a_solutions/<svc>/src/cloud-data-<domain>.json               ║
# ║ (regular file or symlink — the retirement is path-based, not    ║
# ║ contents-based).                                                  ║
# ║                                                                   ║
# ║ Data-driven (FIRE RULE 4): no hardcoded service or domain list.   ║
# ║ Pattern is the entire constraint.                                 ║
# ║                                                                   ║
# ║ Fix when this fails:                                              ║
# ║   git rm a_solutions/<svc>/src/cloud-data-<domain>.json           ║
# ║   (consume _cloud-data-consolidated.json or build-<name>.json     ║
# ║    instead — both are tracked in 2_configs/dist/).                ║
# ║                                                                   ║
# ║ Usage: bash 1_workflows/src/test/test_no_stale_cloud_data_symlinks.sh ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"

echo "── No retired per-domain cloud-data-*.json refs in a_solutions/*/src/ ──"

# Use git ls-files so the test sees only tracked paths (matches CI's view).
# Pattern: a_solutions/<anything>/src/cloud-data-*.json (one path-segment
# under src/). Excludes a_solutions/<svc>/src/code/.../cloud-data-*.json
# because deeper code paths consume cloud-data via _cloud-data-consolidated.json
# legitimately.
mapfile -t HITS < <(
    git ls-files 'a_solutions/*/src/cloud-data-*.json' 2>/dev/null \
        | awk -F/ 'NF == 4'   # exactly a_solutions/<svc>/src/<file>
)

if [ "${#HITS[@]}" -eq 0 ]; then
    echo "  ✓ no retired cloud-data-*.json refs"
    echo
    echo "Phase 31 stale-cloud-data-refs: PASS"
    exit 0
fi

for h in "${HITS[@]}"; do
    printf "  ✗ %s — retired class, use _cloud-data-consolidated.json or build-<name>.json\n" "$h" >&2
done
echo
printf "Phase 31 stale-cloud-data-refs: FAIL — %d retired ref(s) (run: git rm <path>)\n" "${#HITS[@]}" >&2
exit 1
