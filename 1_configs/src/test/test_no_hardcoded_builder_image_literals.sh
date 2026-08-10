#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 34 tester — no hardcoded cloud-builder-x image literals    ║
# ║                                                                  ║
# ║ Wrapper-layer drift guard. The engine scripts read the image     ║
# ║ from III_unix/cb_containers-builders/build.json (data-driven).   ║
# ║ Wrappers (GHA YAMLs, composite actions, orchestrate scripts)     ║
# ║ MUST resolve from the same source — never re-paste the literal.  ║
# ║                                                                  ║
# ║ Root cause this prevents (2026-05-05): build-workflows.json   ║
# ║ shipped `cloud-builder-x:latest` (missing -deb-nixhm suffix);    ║
# ║ engine read it correctly and broke. ~10 hardcoded copies in GHA  ║
# ║ workflows would have continued working — silently masking the    ║
# ║ data drift until the next image rename.                          ║
# ║                                                                  ║
# ║ Allowlist (literal IS expected):                                 ║
# ║   • III_unix/cb_containers-builders/build.json (master)          ║
# ║   • III_unix/cb_containers-builders/src/docker/compose.yaml      ║
# ║   • III_unix/cb_containers-builders/src/docker/entrypoint.sh     ║
# ║   • Comment lines (# / //)                                       ║
# ║   • This test file itself                                        ║
# ║                                                                  ║
# ║ Usage:                                                           ║
# ║   bash 1_configs/src/test/test_no_hardcoded_builder_image_literals.sh
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SELF="${BASH_SOURCE[0]}"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

# Pattern: literal ghcr.io/diegonmarcos/cloud-builder-x... followed by colon (i.e., :tag).
# Catches both the broken short form (cloud-builder-x:latest) and the canonical
# long form (cloud-builder-x-deb-nixhm:latest). Both are forbidden in wrappers
# because both are the symptom: a literal instead of a JSON read.
PATTERN='ghcr\.io/diegonmarcos/cloud-builder-x[a-zA-Z0-9_-]*:'

# Search roots — only places where wrappers live. Engine scripts that resolve
# from JSON are checked separately by Phase 1 (test_arch_runner_routing).
# We scan src/ AND .github/ because both ship to GHA — test_dist_in_sync_with_src
# guarantees they stay aligned after build.sh runs, but a missed rebuild leaves
# .github/ stale; scanning both catches both classes of regression.
SCAN_ROOTS=(
  "$REPO_ROOT/.github/workflows"
  "$REPO_ROOT/.github/actions"
  "$REPO_ROOT/1_configs/src/gha/cicd"
  "$REPO_ROOT/1_configs/src/gha/actions"
  "$REPO_ROOT/1_configs/src/scripts"
  "$REPO_ROOT/1_configs/dist/cicd"
  "$REPO_ROOT/1_configs/dist/actions"
  "$REPO_ROOT/1_configs/dist/scripts"
)
# unix-side wrappers — only the CANONICAL source path (1_configs/src/gha/cicd).
# III_unix/.github/workflows/ is dist and will follow source after rebuild;
# III_unix/workflows/src/static/ is legacy/stale (not the active source).
if [ -d "$REPO_ROOT/III_unix/1_configs/src/gha/cicd" ]; then
  SCAN_ROOTS+=("$REPO_ROOT/III_unix/1_configs/src/gha/cicd")
fi

# Allowlist: paths where the literal IS the source of truth (master + producer).
# Match by repo-relative path suffix.
ALLOWLIST_REGEX='^III_unix/cb_containers-builders/(build\.json$|src/docker/(compose\.yaml|entrypoint\.sh|.*Dockerfile.*))$'

echo "── Scanning wrapper layer for hardcoded image literals ──"
echo "  pattern: $PATTERN"

HITS=()
for root in "${SCAN_ROOTS[@]}"; do
    [ -d "$root" ] || continue
    while IFS= read -r f; do
        rel="${f#$REPO_ROOT/}"
        # Skip self
        [ "$f" = "$SELF" ] && continue
        # Skip allowlisted source-of-truth files
        if [[ "$rel" =~ $ALLOWLIST_REGEX ]]; then continue; fi
        # Find offending lines: pattern present AND not a comment line.
        # YAML/shell comment markers: leading whitespace then #
        # Markdown / docstring comment markers: //
        while IFS= read -r line; do
            HITS+=("$rel:$line")
        done < <(grep -nE "$PATTERN" "$f" 2>/dev/null \
                 | grep -vE '^[0-9]+:\s*#' \
                 | grep -vE '^[0-9]+:\s*//' \
                 || true)
    done < <(find "$root" \( -name '*.yml' -o -name '*.yaml' -o -name '*.sh' -o -name 'action.yml' \) -type f 2>/dev/null)
done

if [ "${#HITS[@]}" -eq 0 ]; then
    pass "no hardcoded cloud-builder-x literals found in wrapper layer"
else
    fail "${#HITS[@]} hardcoded literal(s) found — must read from III_unix/cb_containers-builders/build.json:"
    for h in "${HITS[@]}"; do
        printf "    %s\n" "$h" >&2
    done
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "Phase 34 no-hardcoded-image-literals: PASS"
    exit 0
else
    echo "Phase 34 no-hardcoded-image-literals: FAIL"
    exit 1
fi
