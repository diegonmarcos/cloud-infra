#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_no_stale_cloud_data_symlinks.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
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
# ║ in a_solutions/*/src/cloud-data-*.json → ../../../9_others/     ║
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
# ║    instead — both are tracked in 1_cicd/dist/).                ║
# ║                                                                   ║
# ║ Usage: bash 9_others/test/test_no_stale_cloud_data_symlinks.sh ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

# Repo root by upward search, not a fixed ../../.. — this file exists at BOTH
# 9_others/test/ and 1_cicd/dist/test/ (generated), which sit at
# different depths, so one literal count is wrong for one of the two copies.
REPO_ROOT="$(_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
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
