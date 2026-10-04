#!/bin/sh
# A container service's rendered dist/ must be byte-identical no matter where
# the repos are checked out, and must not move with untracked build outputs.
#
# The bug (2026-10-04, ship 37218863882): step_verify_committed_dist (#864)
# failed 12 services because the render was not deterministic:
#   (a) code/*/Dockerfile carried `# Source: /nix/store/<hash>-source/...`,
#       a hash over the WHOLE cloud-u-containers tree (any commit moves it);
#   (b) dist/.src-hash hashed `sha256sum` output with ABSOLUTE paths, over a
#       `find` that also picked up untracked files (node_modules/, built JS).
#
# Renders the same services from two checkouts at different paths (the second
# one also carrying an untracked node_modules/ + stray .js) and diffs dist/.
#   CONTAINERS_REPO  cloud-u-containers checkout (default: ../cloud-u-containers)
#   DET_SERVICES     services to render (default: a Type-A service-shipped
#                    Dockerfile one, a .src-hash one, and one with an EMPTY
#                    hash input list — that must not fail the build)
# Needs nix; skips (exit 0) when nix or the containers repo is unavailable.
set -eu
REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
CU="${CONTAINERS_REPO:-$REPO_ROOT/../cloud-u-containers}"
SERVICES="${DET_SERVICES:-infra-sec_caddy infra-api_c3-public-api infra-obs_ntfy}"
command -v nix >/dev/null 2>&1 || { echo "  skip (no nix)"; exit 0; }
[ -d "$CU/.git" ] || { echo "  skip (no containers repo at $CU)"; exit 0; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
pass=0; fail=0

# layout: <root>/{1_cicd,1_cloud-configs} + <root>/a_solutions (a clone of the
# containers repo carrying its working-tree edits, so uncommitted engine
# changes are what gets tested).
mk_layout() {
    _root="$1"; mkdir -p "$_root"
    ln -s "$REPO_ROOT/1_cicd" "$_root/1_cicd"
    ln -s "$REPO_ROOT/1_cloud-configs" "$_root/1_cloud-configs"
    git clone -q --shared "$CU" "$_root/a_solutions"
    (cd "$CU" && git diff --binary HEAD) | (cd "$_root/a_solutions" && git apply --allow-empty 2>/dev/null || git apply)
}
mk_layout "$T/one"
mk_layout "$T/second/deeper/checkout"

for svc in $SERVICES; do
    # untracked noise in the second checkout only
    mkdir -p "$T/second/deeper/checkout/a_solutions/$svc/src/node_modules/x"
    echo 'module.exports=1' > "$T/second/deeper/checkout/a_solutions/$svc/src/node_modules/x/index.js"
    echo 'console.log(1)' > "$T/second/deeper/checkout/a_solutions/$svc/src/stray-build-output.js"
    for r in "$T/one" "$T/second/deeper/checkout"; do
        (cd "$r/a_solutions/$svc" && ./build.sh build >"$T/build.log" 2>&1) || {
            fail=$((fail+1)); echo "  FAIL $svc: render failed under $r"; tail -20 "$T/build.log"; continue 2; }
    done
    if d=$(diff -r "$T/one/a_solutions/$svc/dist" "$T/second/deeper/checkout/a_solutions/$svc/dist" 2>&1); then
        pass=$((pass+1)); echo "  ok   $svc: dist/ identical across checkout paths + untracked files"
    else
        fail=$((fail+1)); echo "  FAIL $svc: dist/ differs between checkouts:"; printf '%s\n' "$d" | head -20 | sed 's/^/      /'
    fi
    if grep -rq '/nix/store/' "$T/one/a_solutions/$svc/dist/code" 2>/dev/null; then
        fail=$((fail+1)); echo "  FAIL $svc: dist/code still embeds a /nix/store path"
    else
        pass=$((pass+1)); echo "  ok   $svc: no /nix/store path in dist/code"
    fi
done

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
