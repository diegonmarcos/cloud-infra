#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/cgc-knowledge-repo-root-resolvable.test.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Ticket #402 — the a-knowledge tools of cloud-cgc-pub-mcp resolve repository
# content from a root that does not exist in the deployed container.
#
# WHAT IS BROKEN (measured on oci-apps, container cloud-cgc-pub-mcp, 2026-09-16)
#
#   config.ts:getRepoRoot() returns dirname($CONFIG_PATH). compose.nix derives
#   CONFIG_PATH from .runtime.data_path, so getRepoRoot() is literally /data —
#   and /data is the per-service deploy bind "./data:/data:ro", which in
#   production is an EMPTY directory. It is not a repository and never was.
#
#   Every a-knowledge tool then joins repository paths onto it:
#       docs.ts:20     <repoRoot>/a_solutions/<cloud-spec folder>
#       docs.ts:55     <repoRoot>/README.md
#       docs.ts:70,86  <repoRoot>/a_solutions/<service>
#       specs.ts:12    <repoRoot>/a_solutions
#       configs.ts:76  <repoRoot>/front-data/front-deps.json
#       context.ts:95  <repoRoot>/README.md
#
#   Live proof of the user-visible damage:
#       knowledge_docs method=overview -> "cloud-spec overview.md not found"
#       knowledge_docs method=readme   -> "README.md not found"
#   Both are existsSync() misses reported as prose, so the tool answers a
#   cheerful nothing instead of failing. The content is NOT missing from the
#   image: the octocode_repos volume is mounted read-only at .runtime.git_root
#   (/repos) and carries the real clones —
#       /repos/cloud-u-containers/infra-obs_cloud-spec/src/docs/overview.md
#       /repos/cloud-u-containers/infra-obs_cloud-spec/src/docs/SUMMARY.md
#       /repos/cloud-infra/README.md
#   all present. Only the resolver is pointed at the wrong root.
#
#   The correct pattern already exists in the same codebase and is the one the
#   image is built around: tools/b-code-graph-context/codegraph.ts anchors on
#   process.env.GIT_ROOT (compose.nix sets it from .runtime.git_root) and joins
#   the repo name onto it. a_solutions IS the cloud-u-containers checkout, so
#   <GIT_ROOT>/cloud-u-containers is the real location of every path above.
#
# THE INVARIANT THIS GUARD ENFORCES
#
#   Inside user-ai_cloud-cgc-pub-mcp/src/code, repository content is resolved
#   from the DECLARED .runtime.git_root and never from getRepoRoot(), whose
#   value is .runtime.data_path — a deploy bind that carries no repository.
#   config.ts is the single exception: it defines getRepoRoot() and uses it only
#   as the lowest-priority candidate of getCloudDataPath(), behind /app and
#   behind an existsSync() filter, so it cannot resolve to a phantom path.
#
#   Every fact this guard compares is read from the service's own build.json and
#   compose.nix. Nothing about the layout is written down here a second time, so
#   the guard follows a renamed mount instead of going quietly stale against it.
#
# WHY IT IS REGISTERED "quarantine" IN 9_others/test-registry.json
#
#   The defect is real and is NOT fixed: the resolver lives in
#   diegonmarcos/cloud-u-containers, a different repository. This guard is red
#   on purpose and run-registered-testers.sh asserts it stays red; the day the
#   resolver is moved onto GIT_ROOT the runner goes RED for the opposite reason
#   and demands the flip to "run". It can therefore never decay into a skip.
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)

# cloud-u-containers is checked out at a_solutions/ by lint-pipeline.yml and
# sits beside this repo in a developer/agent clone. Absent means UNRUN, and an
# unrun guard must never read as a passing one.
if   [ -d "$ROOT/a_solutions" ];              then CONTAINERS="$ROOT/a_solutions"
elif [ -d "$ROOT/../cloud-u-containers" ];    then CONTAINERS=$(cd "$ROOT/../cloud-u-containers" && pwd)
else
    echo "::error::cloud-u-containers found neither at $ROOT/a_solutions nor beside $ROOT — this guard cannot run, and refuses to pass."
    exit 1
fi

SERVICE="$CONTAINERS/user-ai_cloud-cgc-pub-mcp"
BUILD_JSON="$SERVICE/build.json"
COMPOSE_NIX="$SERVICE/src/compose.nix"
CODE_DIR="$SERVICE/src/code"

command -v jq >/dev/null || { echo "::error::jq is required by this guard"; exit 1; }

pass=0; fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "  ok   $1"
    else fail=$((fail + 1)); echo "  FAIL $1 (want '$3', got '$2')"; fi
}
present() { [ -e "$1" ] && echo yes || echo no; }
contains() { grep -qF -- "$2" "$1" && echo yes || echo no; }

echo "cloud-cgc-pub-mcp knowledge-tool repository root (#402)"
echo "  service tree: $SERVICE"

# ── 1) the inputs this guard reasons about are all really there ──────────────
check "build.json present"   "$(present "$BUILD_JSON")"  "yes"
check "compose.nix present"  "$(present "$COMPOSE_NIX")" "yes"
check "src/code/ present"    "$(present "$CODE_DIR")"    "yes"
[ "$fail" -eq 0 ] || { echo "::error::the cloud-cgc-pub-mcp service tree is incomplete — refusing to judge it"; exit 1; }

DATA_PATH=$(jq -r '.runtime.data_path // empty' "$BUILD_JSON")
GIT_ROOT=$(jq -r '.runtime.git_root // empty' "$BUILD_JSON")
REPOS_PATH=$(jq -r '.runtime.octocode.repos_path // empty' "$BUILD_JSON")
REPOS_VOLUME=$(jq -r '.runtime.octocode.repos_volume // empty' "$BUILD_JSON")

# ── 2) both roots are declared, absolute, and are not the same directory ─────
# Undeclared is the failure mode that would let check 5 pass vacuously.
check "runtime.data_path is declared absolute" \
      "$(printf '%s' "$DATA_PATH" | grep -qE '^/.' && echo yes || echo no)" "yes"
check "runtime.git_root is declared absolute" \
      "$(printf '%s' "$GIT_ROOT" | grep -qE '^/.' && echo yes || echo no)" "yes"
check "the deploy bind and the repository root are different directories" \
      "$([ "$DATA_PATH" != "$GIT_ROOT" ] && echo yes || echo no)" "yes"
check "octocode.repos_path is the same root as runtime.git_root" "$REPOS_PATH" "$GIT_ROOT"

# ── 3) compose.nix still derives the two env vars from those two keys ────────
# Pinning the derivation is what lets this guard claim getRepoRoot() == data_path
# instead of assuming it. Rewire CONFIG_PATH and the guard demands re-derivation.
check "compose.nix derives CONFIG_PATH from runtime.data_path" \
      "$(contains "$COMPOSE_NIX" 'CONFIG_PATH    = "${buildJson.runtime.data_path}/config.json"')" "yes"
check "compose.nix derives GIT_ROOT from runtime.git_root" \
      "$(contains "$COMPOSE_NIX" 'GIT_ROOT       = buildJson.runtime.git_root')" "yes"

# ── 4) data_path is a deploy bind, git_root is the repos volume ──────────────
# This is the evidence that data_path carries no repository: it is ./data from
# the service's own deploy directory, not a checkout of anything.
check "compose.nix binds data_path from the deploy directory ./data" \
      "$(contains "$COMPOSE_NIX" './data:${buildJson.runtime.data_path}:ro')" "yes"
check "compose.nix mounts the repos volume at repos_path read-only" \
      "$(contains "$COMPOSE_NIX" '${oct.repos_volume}:${oct.repos_path}:ro')" "yes"
check "the repos volume is named" \
      "$(printf '%s' "$REPOS_VOLUME" | grep -q . && echo yes || echo no)" "yes"

# ── 5) THE GUARD: no module outside config.ts resolves content on getRepoRoot ─
# getRepoRoot() is dirname(CONFIG_PATH) is data_path is the empty deploy bind.
# Any module importing it is resolving repository content against a root that
# does not exist in the running container.
offenders=$(grep -rln --include='*.ts' 'getRepoRoot' "$CODE_DIR" \
            | grep -v '/config\.ts$' | sort || true)
check "no module outside config.ts resolves paths on getRepoRoot()" \
      "$([ -z "$offenders" ] && echo yes || echo no)" "yes"
if [ -n "$offenders" ]; then
    echo "       every path below resolves under '$DATA_PATH', which carries no repository."
    echo "       the real location is '$GIT_ROOT/<repo>' — a_solutions is the cloud-u-containers clone."
    for f in $offenders; do
        grep -n 'getRepoRoot' "$f" | while IFS= read -r hit; do
            echo "       ${f#"$CONTAINERS/"}:$hit"
        done
    done
fi

# ── 6) GIT_ROOT is genuinely consumed, so check 5 cannot be met by deletion ──
check "the code reads process.env.GIT_ROOT" \
      "$(grep -rq --include='*.ts' 'process.env.GIT_ROOT' "$CODE_DIR" && echo yes || echo no)" "yes"

echo "  ---- $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
