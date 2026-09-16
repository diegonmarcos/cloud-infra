#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Tester — every agent container declares the shared git tree      ║
# ║                                                                  ║
# ║ Guards #416 (repeat of #345).                                    ║
# ║                                                                  ║
# ║ #345 mounted the one shared checkout (external docker volume     ║
# ║ cloud-git-gh, the tree Gitea serves at /data/git-gh) into        ║
# ║ my-ai_claude-api by hand-copying a PAIR of lines into its        ║
# ║ compose.nix. Three agent containers needed that pair. One got    ║
# ║ it. Nobody noticed for weeks, because a container with no mount  ║
# ║ does not fail — it just reports that the repositories do not     ║
# ║ exist, which is indistinguishable from a bad question. Diego     ║
# ║ found it by asking hermes and being told the code was not there. ║
# ║                                                                  ║
# ║ Proves:                                                          ║
# ║   1. The containers tree is reachable and DOES contain agent     ║
# ║      containers. A run that finds nothing is a FAILURE, never a  ║
# ║      silent pass — that is the whole failure mode being guarded. ║
# ║   2. Every category:"agi" container states agent.git_tree        ║
# ║      EXPLICITLY (true or false). Omission is the #345 defect.    ║
# ║   3. git_tree:true implies an absolute agent.git_tree_mount —    ║
# ║      the engine refuses to guess, so the data must say where.    ║
# ║   4. The external volume name is PINNED wherever the mount is    ║
# ║      produced. Without the pin compose invents a project-scoped  ║
# ║      volume and mounts an EMPTY directory with no error, which   ║
# ║      looks exactly like the bug this guards.                     ║
# ║                                                                  ║
# ║ Usage: bash 9_others/test/test_agent_git_tree_declared.sh        ║
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
if   [ -d "$REPO_ROOT/a_solutions" ];                 then CONTAINERS="$REPO_ROOT/a_solutions"
elif [ -d "$(dirname "$REPO_ROOT")/cloud-u-containers" ]; then CONTAINERS="$(dirname "$REPO_ROOT")/cloud-u-containers"
else CONTAINERS=""
fi

ENGINE="$CONTAINERS/_shared/engine.nix"
VOLUME_NAME="cloud-git-gh"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── 1: container definitions are reachable ──"
if [ -z "$CONTAINERS" ]; then
    fail "cloud-u-containers not found at a_solutions/ nor beside $REPO_ROOT — cannot verify any agent container. Refusing to pass."
    exit 1
fi
pass "containers tree: $CONTAINERS"

# ── collect the agent containers, data-driven from build.json category ───────
AGENTS=()
for bj in "$CONTAINERS"/*/build.json; do
    [ -f "$bj" ] || continue
    case "$bj" in */z_archive/*) continue ;; esac
    if [ "$(jq -r '.category // ""' "$bj")" = "agi" ]; then
        AGENTS+=("$bj")
    fi
done

if [ "${#AGENTS[@]}" -eq 0 ]; then
    fail "found ZERO category:\"agi\" containers under $CONTAINERS. Either the tree is wrong or the category was renamed; a guard that inspects nothing is worse than no guard."
    exit 1
fi
pass "found ${#AGENTS[@]} agent container(s) with category \"agi\""

echo ""
echo "── 2: the engine still pins the external volume name ──"
# Every flag-driven mount inherits its pin from this one line. If it is ever
# dropped, all of them silently become per-project empty volumes at once.
if [ -f "$ENGINE" ] && grep -E "gitTreeName[[:space:]]*=[[:space:]]*\"$VOLUME_NAME\"" "$ENGINE" >/dev/null 2>&1; then
    pass "engine.nix pins gitTreeName = \"$VOLUME_NAME\""
else
    fail "engine.nix does not pin gitTreeName = \"$VOLUME_NAME\" — every agent.git_tree mount would become a project-scoped EMPTY volume"
fi

echo ""
echo "── 3: every agent container decides, and a decision is honoured ──"
for bj in "${AGENTS[@]}"; do
    dir="$(dirname "$bj")"
    svc="$(basename "$dir")"
    compose="$dir/src/compose.nix"

    declared="$(jq -r 'if (.agent | type) == "object" and (.agent | has("git_tree"))
                       then (.agent.git_tree | tostring) else "unset" end' "$bj")"

    # Legacy shape: the mount written by hand in compose.nix (my-ai_claude-api
    # still carries #345's original pair). That satisfies the requirement — this
    # guard checks the OUTCOME, not which mechanism produced it.
    legacy_mount=0
    legacy_pin=0
    if [ -f "$compose" ]; then
        grep -E "\"git_gh:[^\"]+\"" "$compose" >/dev/null 2>&1 && legacy_mount=1
        grep -E "name[[:space:]]*=[[:space:]]*\"$VOLUME_NAME\"" "$compose" >/dev/null 2>&1 && legacy_pin=1
    fi

    if [ "$declared" = "unset" ]; then
        if [ "$legacy_mount" -eq 1 ]; then
            if grep -E "\"git_gh:[^\"]+:ro\"" "$compose" >/dev/null 2>&1; then
                fail "$svc: compose.nix mounts git_gh with :ro — the shared tree is this agent's own working directory and must be read-write. Drop the :ro suffix."
            elif [ "$legacy_pin" -eq 1 ]; then
                pass "$svc: mounts the tree explicitly in compose.nix, read-write, external name pinned"
            else
                fail "$svc: compose.nix mounts git_gh but never pins name = \"$VOLUME_NAME\" — compose will create a project-scoped EMPTY volume"
            fi
        else
            fail "$svc: category \"agi\" but build.json has no agent.git_tree. This is exactly the #345/#416 defect: a new agent container added without a decision gets NO shared tree and reports the repositories as missing. Set agent.git_tree true or false."
        fi
        continue
    fi

    if [ "$declared" = "true" ]; then
        mount="$(jq -r '.agent.git_tree_mount // ""' "$bj")"
        writable="$(jq -r '.agent.git_tree_writable // false' "$bj")"
        # The tree is mounted at the container's own $HOME/git — it is the
        # agent's WORKING DIRECTORY, not a reference copy. #416 shipped it
        # read-only and the guard happily printed "(read-only)" as a pass, so
        # an agent that could not edit, commit or push a single one of the six
        # repositories looked fully provisioned. A guard that narrates the
        # defect instead of failing on it is the defect.
        if [ "$writable" != "true" ]; then
            fail "$svc: agent.git_tree_writable is \"$writable\" — the shared tree mounts at $mount, which is this agent's own working directory. Read-only there is never right: set agent.git_tree_writable true."
            continue
        fi
        case "$mount" in
            /*) pass "$svc: git_tree true, mount $mount (read-write)" ;;
            "") fail "$svc: agent.git_tree is true but agent.git_tree_mount is missing — the engine will throw at build time" ;;
            *)  fail "$svc: agent.git_tree_mount \"$mount\" is not an absolute path" ;;
        esac
    elif [ "$declared" = "false" ]; then
        reason="$(jq -r '.agent._comment // ""' "$bj")"
        if [ -n "$reason" ]; then
            pass "$svc: git_tree false, reason recorded"
        else
            fail "$svc: opts out with agent.git_tree false but records no agent._comment saying why — an undocumented opt-out is how the next one gets missed"
        fi
    else
        fail "$svc: agent.git_tree is \"$declared\", expected boolean true or false"
    fi
done

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "PASS — every agent container declares the shared git tree (#416 guard)"
else
    echo "FAIL — an agent container is missing or mis-declaring the shared git tree" >&2
fi
exit "$FAIL"
