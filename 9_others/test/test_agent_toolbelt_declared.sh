#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Tester — every AI container ships every declared toolbelt tool    ║
# ║                                                                  ║
# ║ Guards #366 / Task 450 / #527.                                   ║
# ║                                                                  ║
# ║ gh is how every dispatched agent in this fleet proves its own CI ║
# ║ went green. With no `gh`, an agent told to "watch your CI to      ║
# ║ green" runs `gh run view`, gets `gh: not found`, and reports     ║
# ║ green having checked nothing — the failure renders identically   ║
# ║ to success. That is the fail-open #366 existed to close.         ║
# ║                                                                  ║
# ║ #509 (2026-09-18) replaced three per-service hand-written tool   ║
# ║ lists (hermes build.json's runtime_packages/runtime_extra_run    ║
# ║ and the gh/yq/ripgrep install block in each of the two agent     ║
# ║ Dockerfiles) with ONE shared declaration:                        ║
# ║   cloud-u-containers/_shared/agent-toolbelt.json                 ║
# ║ consumed by _shared/engine.nix two ways:                         ║
# ║   - hermes-agent (Type-B, wraps an upstream image) opts in with  ║
# ║     build.json#docker.agent_toolbelt = true;                     ║
# ║   - my-ai-api and my-ai_claude-api (Type-A, own Dockerfiles)     ║
# ║     splice it via the @AGENT_TOOLBELT_APT@ /                     ║
# ║     @AGENT_TOOLBELT_EXTRA_RUN@ placeholders.                     ║
# ║                                                                  ║
# ║ The literal "ripgrep" / "/usr/local/bin/gh" substrings the guard ║
# ║ used to grep for are GONE from those files BY DESIGN — they now  ║
# ║ come from agent-toolbelt.json via engine.nix. Grepping filenames ║
# ║ or literal install text is exactly the defect shape that turned  ║
# ║ this guard red (#527): it re-breaks the moment anything moves.   ║
# ║ So this tester asserts the PROPERTY, not a location:             ║
# ║                                                                  ║
# ║   1. the one declaration exists, is valid JSON and is non-empty  ║
# ║      (apt_packages, binaries, gh/yq tarballs).                   ║
# ║   2. every container the declaration claims carries the toolbelt ║
# ║      actually resolves to a real build file — a declared path    ║
# ║      that resolves to nothing is a FAIL, never a skip.           ║
# ║   3. every one of those containers is wired to the declaration   ║
# ║      (Type-B opt-in flag, or the two Type-A placeholders).       ║
# ║   4. engine.nix still reads the declaration and splices it, so a ║
# ║      tool added to the declaration reaches all three containers. ║
# ║   5. every declared binary resolves to an actual install source  ║
# ║      (an apt package in the list, a tarball, or the base image). ║
# ║      A tool that is declared but installed NOWHERE is a FAILURE. ║
# ║                                                                  ║
# ║ Mutation contract: removing any declared tool's install source   ║
# ║ from agent-toolbelt.json while it stays declared in binaries, or ║
# ║ deleting the declaration file itself, or unwiring a container,   ║
# ║ must turn this tester RED. A guard that has only ever been seen  ║
# ║ passing is not proven (#284, #363, #376); see Task 450 / #509 /  ║
# ║ #527 definitions of done for the red/green pair.                 ║
# ╚══════════════════════════════════════════════════════════════════╝
set -euo pipefail

# Repo root by upward search, not a fixed ../../.. — testers in this repo are
# copied to a second location at a different depth, so one literal count is
# wrong for one of the two copies.
REPO_ROOT="$(_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"

# The container definitions live in diegonmarcos/cloud-u-containers, a plain
# sibling repository (NOT a submodule since 2026-09-06). CI checks it out at
# a_solutions/; a developer clone has it beside this repo. Both are real
# layouts, so accept either. An unresolvable subject is a FAIL, never a skip:
# a tester that cannot find its declaration must not read as coverage.
if   [ -d "$REPO_ROOT/a_solutions" ];                     then CONTAINERS="$REPO_ROOT/a_solutions"
elif [ -d "$(dirname "$REPO_ROOT")/cloud-u-containers" ]; then CONTAINERS="$(dirname "$REPO_ROOT")/cloud-u-containers"
else CONTAINERS=""
fi

ENGINE_NIX="$CONTAINERS/_shared/engine.nix"
TOOLBELT_JSON="$CONTAINERS/_shared/agent-toolbelt.json"

# Binaries that are NOT installed by this declaration but by the base image
# the container wraps. Everything else must resolve to an apt package from the
# declaration's apt_packages list or to a tarball. `git` is the upstream
# image's own tool; it is verified (`command -v`) but not installed here.
# Base-image-provided binaries are the extension point: if the fleet ever
# relies on a NEW binary from the base, list it here too and document why.
BASE_PROVIDED_BINARIES="git"

FAIL=0
pass() { printf "  \u2713 %s\n" "$1"; }
fail() { printf "  \u2717 %s\n" "$1" >&2; FAIL=1; }

echo "── 0: the single shared declaration is reachable ──"
if [ -z "$CONTAINERS" ]; then
    fail "cloud-u-containers not found at a_solutions/ nor beside $REPO_ROOT — cannot verify any toolbelt. Refusing to pass."
    exit 1
fi
pass "containers tree: $CONTAINERS"
if [ ! -f "$TOOLBELT_JSON" ]; then
    fail "_shared/agent-toolbelt.json not found at $TOOLBELT_JSON — the ONE declaration every AI container consumes is gone."
    exit 1
fi
if ! jq -e . "$TOOLBELT_JSON" >/dev/null 2>&1; then
    fail "$TOOLBELT_JSON is not valid JSON — the declaration is unreadable."
    exit 1
fi

echo ""
echo "── 1: the declaration exists, parses and is non-trivial ──"
apt_count="$(jq -r '.apt_packages // [] | length' "$TOOLBELT_JSON")"
bin_count="$(jq -r '.binaries // [] | length' "$TOOLBELT_JSON")"
tarball_count="$(jq -r '.tarballs // {} | length' "$TOOLBELT_JSON")"
if [ "$apt_count" -gt 0 ] && [ "$bin_count" -gt 0 ] && [ "$tarball_count" -gt 0 ]; then
    pass "declares $apt_count apt package(s), $bin_count verified binarie(s), $tarball_count tarball tool(s)"
else
    fail "agent-toolbelt.json is empty or malformed (apt=$apt_count binaries=$bin_count tarballs=$tarball_count) — the declaration has been emptied."
fi
if jq -e '.tarballs.gh.version and .tarballs.yq.version' "$TOOLBELT_JSON" >/dev/null 2>&1; then
    pass "declares gh / yq tarball versions"
else
    fail "agent-toolbelt.json no longer declares gh and/or yq with a version — the #366 fail-open would return."
fi
# The declaration's `containers` array is the authoritative list of everyone
# who must carry the toolbelt. It must name all three AI containers explicitly,
# so a fourth added without opting in trips this guard.
container_names="$(jq -r '.containers[]?.name' "$TOOLBELT_JSON" | tr '\n' ' ')"
if [ -n "$container_names" ]; then
    pass "declaration names container(s): $(echo "$container_names" | sed 's/ $//')"
else
    fail "agent-toolbelt.json declares NO containers — nothing is named as a toolbelt carrier."
fi
for need in "my-ai_claude-api" "my-ai-api" "hermes-agent"; do
    if jq -e --arg n "$need" 'any(.containers[]?; .name == $n)' "$TOOLBELT_JSON" >/dev/null 2>&1; then
        pass "  container $need is declared"
    else
        fail "  container $need is NOT in the declaration's containers list — it would silently lose the toolbelt."
    fi
done

echo ""
echo "── 2: every declared container resolves to a real build file ──"
# Requirement #527 part 3: a declared path that resolves to nothing is a FAIL,
# never a skip. An empty resolution must be red, not ignored (the exact way the
# sibling tester in cloud-u-android went blind: 130 passed / 0 failed on a tree
# that was plainly wrong).
# A Type-B container carries the toolbelt through its build.json (docker.agent_
# toolbelt flag); a Type-A container through its own Dockerfile. Whichever file
# the declaration names for that container MUST exist.
while read -r name kind dir dockerfile build_json; do
    [ -n "$name" ] || continue
    if [ "$dockerfile" != "-" ]; then
        full="$CONTAINERS/$dir/$dockerfile"
        if [ -f "$full" ]; then
            pass "$name build file resolves: $dir/$dockerfile"
        else
            fail "$name's declared Dockerfile does not resolve: $CONTAINERS/$dir/$dockerfile is MISSING — a declared path that resolves to nothing is a red, not a skip."
        fi
    elif [ "$build_json" != "-" ]; then
        full="$CONTAINERS/$dir/$build_json"
        if [ -f "$full" ]; then
            pass "$name build file resolves: $dir/$build_json"
        else
            fail "$name's declared build.json does not resolve: $CONTAINERS/$dir/$build_json is MISSING — a declared path that resolves to nothing is a red, not a skip."
        fi
    else
        fail "$name declares NEITHER a dockerfile nor a build_json — the toolbelt carrier has no build file to verify."
    fi
done < <(jq -r '.containers[] | [.name, .kind, .dir, (.dockerfile // "-"), (.build_json // "-")] | @tsv' "$TOOLBELT_JSON")

echo ""
echo "── 3: every declared container is wired to the declaration ──"
# Type-B (wrapped image): build.json must set docker.agent_toolbelt=true.
# Type-A (own Dockerfile): the Dockerfile must splice both placeholders.
check_wiring() {
    local name="$1" kind="$2" dir="$3" buildfile="$4" dockerfile="$5"
    if [ "$kind" = "type-b" ]; then
        local bj="$CONTAINERS/$dir/$buildfile"
        if [ ! -f "$bj" ]; then
            fail "$name (Type-B): build.json not found at $dir/$buildfile — cannot verify wiring."
        elif jq -e '.docker.agent_toolbelt == true' "$bj" >/dev/null 2>&1; then
            pass "$name sets docker.agent_toolbelt=true"
        else
            fail "$name (Type-B): build.json does NOT set docker.agent_toolbelt=true — it would fall back to (or lose) its own per-service list and drift from the shared declaration."
        fi
    else
        local df="$CONTAINERS/$dir/$dockerfile"
        if [ ! -f "$df" ]; then
            fail "$name (Type-A): Dockerfile not found at $dir/$dockerfile — cannot verify wiring."
        else
            if grep -qF "@AGENT_TOOLBELT_APT@" "$df"; then
                pass "$name Dockerfile splices @AGENT_TOOLBELT_APT@"
            else
                fail "$name Dockerfile no longer splices @AGENT_TOOLBELT_APT@ — it has drifted back to a hand-written package list, disconnected from agent-toolbelt.json."
            fi
            if grep -qF "@AGENT_TOOLBELT_EXTRA_RUN@" "$df"; then
                pass "$name Dockerfile splices @AGENT_TOOLBELT_EXTRA_RUN@"
            else
                fail "$name Dockerfile no longer splices @AGENT_TOOLBELT_EXTRA_RUN@ — an agent here could report green having checked nothing (#366)."
            fi
        fi
    fi
}
# Iterate the declaration's containers as the source of truth.
while read -r name kind dir dockerfile build_json; do
    check_wiring "$name" "$kind" "$dir" "$build_json" "$dockerfile"
done < <(jq -r '.containers[] | [.name, .kind, .dir, (.dockerfile // "-"), (.build_json // "-")] | @tsv' "$TOOLBELT_JSON")

echo ""
echo "── 4: engine.nix still derives the toolbelt from the one declaration ──"
if [ ! -f "$ENGINE_NIX" ]; then
    fail "engine.nix not found at $ENGINE_NIX — the toolbelt hooks cannot be verified."
else
    # A tool added to agent-toolbelt.json only reaches all three containers if
    # the build engine still reads that file and splices it both ways.
    if grep -qF "agent-toolbelt.json" "$ENGINE_NIX"; then
        pass "engine.nix still reads _shared/agent-toolbelt.json"
    else
        fail "engine.nix no longer reads agent-toolbelt.json — the single declaration is orphaned."
    fi
    if grep -qF "agentToolbelt" "$ENGINE_NIX" && grep -qE "apt_packages" "$ENGINE_NIX" && grep -qE "binaries" "$ENGINE_NIX"; then
        pass "engine.nix still derives apt + binary lists from the declaration's fields"
    else
        fail "engine.nix no longer derives apt_packages / binaries from agent-toolbelt.json — it has drifted to a hardcoded parallel list."
    fi
    if grep -qF "docker.agent_toolbelt" "$ENGINE_NIX"; then
        pass "engine.nix still honours docker.agent_toolbelt (Type-B opt-in)"
    else
        fail "engine.nix no longer honours docker.agent_toolbelt — hermes-agent's opt-in flag would be silently ignored."
    fi
    if grep -qF "AGENT_TOOLBELT_APT" "$ENGINE_NIX" && grep -qF "AGENT_TOOLBELT_EXTRA_RUN" "$ENGINE_NIX"; then
        pass "engine.nix still splices @AGENT_TOOLBELT_APT@ / @AGENT_TOOLBELT_EXTRA_RUN@ (Type-A)"
    else
        fail "engine.nix no longer splices the Type-A placeholders — my-ai-api / my-ai_claude-api's Dockerfiles would ship the literal, un-substituted placeholder text."
    fi
fi

echo ""
echo "── 5: every declared tool is installed somewhere (declared-but-nowhere = FAIL) ──"
# The core property: for every binary the declaration says must be present,
# there must be an actual install source — an apt package in the list, a
# tarball, or a base-image build-in. A binary that resolves to none of those
# would fail `command -v` at build time: it is declared but installed NOWHERE,
# which is a FAILURE, not a quirk to skip (#527 part 2).
#
# apt package -> binaries it provides, so a binary like `ps` is counted as
# installed when `procps` is in the apt list even though their names differ.
# Kept data-driven against the declaration, not a location-grep.
apt_provides() {
    # $1 = the package name actually present in the declaration.
    case "$1" in
        procps)         echo "ps top watch free vmstat uptime" ;;
        psmisc)         echo "pstree killall fuser" ;;
        iproute2)       echo "ss ip" ;;
        net-tools)      echo "netstat ifconfig route" ;;
        iputils-ping)   echo "ping ping6" ;;
        dnsutils)       echo "dig host nslookup" ;;
        netcat-openbsd) echo "nc netcat" ;;
        sysstat)        echo "iostat sar" ;;
        openssh-client) echo "ssh scp sftp ssh-keygen" ;;
        xz-utils)       echo "xz" ;;
        ripgrep)        echo "rg" ;;
    esac
}
# Set of every binary the declaration guarantees, keyed by name, along with the
# route that installs it: tarball key, apt package name, or base-image build-in.
declare -A GUARANTEED=()
# Binary is provided by a tarball (gh, yq) or by an apt package whose own name
# matches the binary (jq, curl, htop, lsof, ...).
for t in $(jq -r '.tarballs | keys[]' "$TOOLBELT_JSON"); do GUARANTEED["$t"]="tarball:$t"; done
for a in $(jq -r '.apt_packages[]' "$TOOLBELT_JSON"); do
    GUARANTEED["$a"]="apt:$a"
    for b in $(apt_provides "$a"); do GUARANTEED["$b"]="apt-provides:$a"; done
done
for b in $BASE_PROVIDED_BINARIES; do GUARANTEED["$b"]="base-image"; done
uncovered=0
while read -r b; do
    [ -n "$b" ] || continue
    if [ "${GUARANTEED[$b]+1}" = "1" ]; then
        pass "  binary $b <- ${GUARANTEED[$b]}"
    else
        fail "  binary $b is DECLARED but installed NOWHERE (no tarball, no matching apt package, no base-image source) — this is a failure, not a skip."
        uncovered=$((uncovered + 1))
    fi
done < <(jq -r '.binaries[]' "$TOOLBELT_JSON")
if [ "$uncovered" -eq 0 ]; then
    pass "every declared binary resolves to a real install source"
else
    fail "$uncovered declared binary(ies) have no install source — the toolbelt would fail its own runtime verification."
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "PASS — the agent toolbelt property holds: every declared container ships every declared tool (#366 / Task 450 / #527 guard)"
else
    echo "FAIL — the agent toolbelt property is violated: a declared container or tool cannot be verified" >&2
fi
exit "$FAIL"
