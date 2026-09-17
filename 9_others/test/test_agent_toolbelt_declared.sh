#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Tester — every agent container still ships the toolbelt          ║
# ║                                                                  ║
# ║ Guards #366 / Task 450.                                          ║
# ║                                                                  ║
# ║ gh is how every dispatched agent in this fleet proves its own CI ║
# ║ went green. With no `gh`, an agent told to \"watch your CI to      ║
# ║ green\" runs `gh run view`, gets `gh: not found`, and reports     ║
# ║ green having checked nothing — the failure renders identically   ║
# ║ to success. That is the fail-open #366 existed to close.         ║
# ║                                                                  ║
# ║ The toolbelt is declared TWO ways today:                         ║
# ║   - hermes-agent wraps an upstream image and installs gh / yq    ║
# ║     through engine.nix's runtime_extra_run / runtime_packages    ║
# ║     hook, declared in user-ai_hermes-agent/build.json.           ║
# ║   - my-ai-api and my-ai_claude-api ship their own Dockerfiles    ║
# ║     and install gh / yq / ripgrep directly in them.              ║
# ║                                                                  ║
# ║ On 2026-09-17 an agent deleted ALL of it at once: the two hook   ║
# ║ definitions out of engine.nix, the runtime_packages +            ║
# ║ runtime_extra_run block out of hermes-agent/build.json, and the  ║
# ║ gh / yq / ripgrep install block out of BOTH agent Dockerfiles.   ║
# ║ Nothing in CI noticed: no test asserted the toolbelt survives.   ║
# ║ This is that assertion. It fails the build when any one of the   ║
# ║ three declarations disappears.                                   ║
# ║                                                                  ║
# ║ Mutation contract: the gh install line in EITHER Dockerfile is   ║
# ║ probe-sized — deleting it must make this tester go RED. A guard  ║
# ║ that has only ever been seen passing is not proven (#284, #363,  ║
# ║ #376); see Task 450 definition of done for the red/green pair.   ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

# Repo root by upward search, not a fixed ../../.. — testers in this repo are
# copied to a second location at a different depth, so one literal count is
# wrong for one of the two copies.
REPO_ROOT="$(_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"

# The container definitions live in diegonmarcos/cloud-u-containers, which is a
# plain sibling repository (NOT a submodule since 2026-09-06). CI checks it out
# at a_solutions/; a developer clone has it beside this repo. Both are real
# layouts, so accept either — and fail loudly if neither is present rather than
# skipping, because a tester that cannot find its subject must not report PASS.
if   [ -d "$REPO_ROOT/a_solutions" ];                     then CONTAINERS="$REPO_ROOT/a_solutions"
elif [ -d "$(dirname "$REPO_ROOT")/cloud-u-containers" ]; then CONTAINERS="$(dirname "$REPO_ROOT")/cloud-u-containers"
else CONTAINERS=""
fi

ENGINE_NIX="$CONTAINERS/_shared/engine.nix"
HERMES_JSON="$CONTAINERS/user-ai_hermes-agent/build.json"
API_DOCKERFILE="$CONTAINERS/user-ai_my-ai-api/src/code/Dockerfile"
CLAUDE_DOCKERFILE="$CONTAINERS/user-ai_my-ai_claude-api/src/code/Dockerfile"
HERMES_AGENTS_SERVICE="user-ai_hermes-agent"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── 0: container definitions are reachable ──"
if [ -z "$CONTAINERS" ]; then
    fail "cloud-u-containers not found at a_solutions/ nor beside $REPO_ROOT — cannot verify any toolbelt. Refusing to pass."
    exit 1
fi
pass "containers tree: $CONTAINERS"

echo ""
echo "── 1: engine.nix still provides the runtime hook ──"
# The hook: build.json#docker.runtime_packages (apt/apk lists) and
# build.json#docker.runtime_extra_run (verbatim RUN commands) let a Type-B
# service extend the image without a service-local Dockerfile. If either line
# vanishes, hermes-agent (which declares its toolbelt through the hook) loses
# its gh / yq installs and nothing elsewhere notices.
if [ ! -f "$ENGINE_NIX" ]; then
    fail "engine.nix not found at $ENGINE_NIX — the toolbelt hook cannot be verified."
else
    if grep -qF "runtime_packages" "$ENGINE_NIX"; then
        pass "engine.nix still reads docker.runtime_packages"
    else
        fail "engine.nix no longer defines runtime_packages — hermes-agent declares its gh / yq install through this hook."
    fi
    if grep -qF "runtime_extra_run" "$ENGINE_NIX"; then
        pass "engine.nix still emits docker.runtime_extra_run RUN commands"
    else
        fail "engine.nix no longer defines runtime_extra_run — a service cannot declare extra install steps, so hermes-agent's toolbelt cannot ship (#366 was the precise reason this hook exists)."
    fi
fi

echo ""
echo "── 2: hermes-agent still declares its toolbelt through the hook ──"
if [ ! -f "$HERMES_JSON" ]; then
    fail "build.json not found at $HERMES_JSON — cannot verify hermes-agent's toolbelt declaration."
elif ! jq -e '.docker | has("runtime_extra_run") and has("runtime_packages")' "$HERMES_JSON" >/dev/null 2>&1; then
    fail "$HERMES_AGENTS_SERVICE no longer declares docker.runtime_extra_run AND docker.runtime_packages. Both were deleted together on 2026-09-17; the runtime hook engine.nix provides is only as good as the service that uses it."
else
    extra_run="$(jq -r '.docker.runtime_extra_run // [] | length' "$HERMES_JSON" 2>/dev/null)"
    if [ "$extra_run" -gt 0 ]; then
        pass "$HERMES_AGENTS_SERVICE declares runtime_extra_run with $extra_run command(s)"
    else
        fail "$HERMES_AGENTS_SERVICE declares an EMPTY runtime_extra_run — the hook exists but installs nothing."
    fi
    # The point of the hook for this fleet is the gh install. Assert the
    # declared block actually targets /usr/local/bin/gh, so a toolbelt that
    # dwindles to nothing still trips the guard.
    if grep -qF "/usr/local/bin/gh" "$HERMES_JSON"; then
        pass "$HERMES_AGENTS_SERVICE runtime_extra_run still installs gh"
    else
        fail "$HERMES_AGENTS_SERVICE runtime_extra_run no longer installs gh — the #366 fail-open would return."
    fi
fi

echo ""
echo "── 3: both self-hosted agent Dockerfiles still install gh, yq, ripgrep ──"
check_dockerfile() {
    local label="$1" file="$2"
    if [ ! -f "$file" ]; then
        fail "$label Dockerfile not found at $file — cannot verify its toolbelt."
        return
    fi
    local missing=0
    for tool in gh yq ripgrep; do
        case "$tool" in
            gh)
                # The gh install is inferred by its install target, which is
                # probe-sized: deleting the install line removes this exact
                # string and turns the guard RED.
                if grep -qF "/usr/local/bin/gh" "$file"; then
                    pass "$label Dockerfile installs gh"
                else
                    fail "$label Dockerfile no longer installs gh — an agent here would report green having checked nothing (#366)."
                    missing=$((missing + 1))
                fi
                ;;
            yq)
                if grep -qF "/usr/local/bin/yq" "$file"; then
                    pass "$label Dockerfile installs yq"
                else
                    fail "$label Dockerfile no longer installs yq."
                    missing=$((missing + 1))
                fi
                ;;
            ripgrep)
                if grep -qE "ripgrep" "$file"; then
                    pass "$label Dockerfile installs ripgrep"
                else
                    fail "$label Dockerfile no longer installs ripgrep."
                    missing=$((missing + 1))
                fi
                ;;
        esac
    done
}
check_dockerfile "my-ai-api"        "$API_DOCKERFILE"
check_dockerfile "my-ai_claude-api" "$CLAUDE_DOCKERFILE"

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "PASS — the agent toolbelt is still declared everywhere (#366 / Task 450 guard)"
else
    echo "FAIL — the agent toolbelt declaration has been removed or emptied" >&2
fi
exit "$FAIL"