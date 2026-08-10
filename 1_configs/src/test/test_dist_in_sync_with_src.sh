#!/usr/bin/env bash
# Test: 1_configs/dist/ + .github/workflows/ are in sync with the
# corresponding src/cicd/ + src/scripts/ + src/test/.
#
# Why: today (2026-04-27) saw multiple agents push src changes without
# running 1_configs/build.sh deploy. Result: .github/workflows/ on
# origin diverged from src/cicd/ by 2+ commits, and ship runs failed at
# the matrix-detect step (cloud-data-gha-config.json missing because
# the regen pre-step lived in src but never got deployed).
#
# Fix: this lint runs `1_configs/build.sh build` then checks that
# dist/ + .github/workflows/ match what the engine emits. Any drift
# fails the lint with a clear message pointing at the build step.
set -eu

# Repo root by upward search, not a fixed ../../.. — this file exists at BOTH
# 1_configs/src/test/ and 1_configs/dist/test/ (generated), which sit at
# different depths, so one literal count is wrong for one of the two copies.
REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"

[ -f "$REPO_ROOT/1_configs/build.sh" ] || { echo "::error::build.sh not found"; exit 1; }

# Snapshot dist + .github/workflows BEFORE build, then re-build, diff.
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

# Snapshot dist/ verbatim. .github/workflows has symlinks (scripts/, hooks/,
# test/) into dist — so we snapshot only .yml files, not the symlinked dirs.
# The dirs themselves are part of the dist/ check above; double-comparing
# them via the symlink fails with "No such file or directory" when cp
# behaves oddly with broken/replaced symlinks.
cp -r "$REPO_ROOT/1_configs/dist" "$TMP/dist-before" 2>/dev/null || true
mkdir -p "$TMP/wf-before"
find "$REPO_ROOT/.github/workflows" -maxdepth 1 -name '*.yml' -exec cp {} "$TMP/wf-before/" \; 2>/dev/null || true

# Re-emit dist + .github/workflows from src/.
( cd "$REPO_ROOT" && bash 1_configs/build.sh ) >/dev/null 2>&1 || {
    echo "::error::1_configs/build.sh failed — fix the engine before lint"
    exit 1
}

DRIFT=0

# --no-dereference: dist/ legitimately holds symlinks that point into
# submodule build outputs (e.g. front-fleet-gh-declared.json →
# III_front/2_configs/dist/). Those targets are absent unless the
# submodule has been built, and without this flag diff reports the
# dangling link as "No such file or directory" and the test fails for
# a reason that has nothing to do with src→dist drift. Comparing the
# link targets themselves is also the more correct check here: the
# engine owns the link, not the file behind it.
if ! diff -rq --no-dereference "$TMP/dist-before" "$REPO_ROOT/1_configs/dist" >/tmp/dist-drift 2>&1; then
    if [ -s /tmp/dist-drift ]; then
        echo "::error::1_configs/dist/ is out of sync with 1_configs/src/"
        echo "Drift:"
        head -20 /tmp/dist-drift | sed 's/^/  /'
        echo "Fix: run 'bash 1_configs/build.sh' and commit the dist/ changes."
        DRIFT=1
    fi
fi

# Compare only the .yml workflow files; symlinked subdirs (scripts, hooks,
# test) are validated as part of the dist/ check above.
WF_DRIFT=$(
    for f in "$REPO_ROOT/.github/workflows/"*.yml; do
        [ -f "$f" ] || continue
        bn=$(basename "$f")
        before="$TMP/wf-before/$bn"
        if [ ! -f "$before" ] || ! cmp -s "$before" "$f"; then
            echo "  $bn drifts"
        fi
    done
    for f in "$TMP/wf-before/"*.yml; do
        [ -f "$f" ] || continue
        bn=$(basename "$f")
        [ -f "$REPO_ROOT/.github/workflows/$bn" ] || echo "  $bn removed by build but still in .github/workflows/ snapshot"
    done
)
if [ -n "$WF_DRIFT" ]; then
    echo "::error::.github/workflows/ is out of sync with 1_configs/src/gha/cicd/"
    echo "Drift:"
    printf '%s\n' "$WF_DRIFT"
    echo "Fix: run 'bash 1_configs/build.sh' and commit the .github/workflows/ changes."
    DRIFT=1
fi

[ "$DRIFT" -eq 1 ] && exit 1

echo "1_configs/dist/ + .github/workflows/ are in sync with src/."
