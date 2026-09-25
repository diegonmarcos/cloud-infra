#!/usr/bin/env bash
# #569 — every repo carries the SAME dotfiles, from ONE declaration.
#
# Part 1 (always): the emitter/guard deploy-dotfiles-fleet.sh against a fixture
#   fleet — a repo that is in sync, one with a stale .mcp.json SYMLINK, a
#   drifted .claude file, a stale module copy, a repo with no module, and an
#   absent repo. Asserts --check goes RED on each, the emit repairs them, and a
#   second --check goes GREEN. Mutation-proven: make `sync` never report drift
#   and cases C1-C4 go red.
# Part 2 (always): the REAL manifest + dist are coherent — fleet lists real repos,
#   the .mcp.json we ship is the deriver's output and names every fleet server.
# Part 3 (CI, or FLEET_LIVE=1): the real fleet, fetched from GitHub (public repos
#   only) or read from $CLOUD_GIT_BASE, must have zero drift.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FLEET="$ROOT/9_others/src/deploy-dotfiles-fleet.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
expect() { # expect <name> <want-exit> <grep-pattern-or-""> -- cmd...
    local name="$1" want="$2" pat="$3"; shift 4
    local out rc; out="$("$@" 2>&1)"; rc=$?
    if [ "$rc" != "$want" ]; then bad "$name (exit $rc, want $want)"; echo "$out" | sed 's/^/    /'; return; fi
    if [ -n "$pat" ] && ! grep -Eq "$pat" <<<"$out"; then bad "$name (output lacks /$pat/)"; echo "$out" | sed 's/^/    /'; return; fi
    ok "$name"
}

# ── fixture ────────────────────────────────────────────────────────────────
S="$T/src"; D="$T/dist"; B="$T/base"
mkdir -p "$S" "$D/claude" "$D/vscode" "$D/root" "$B"
printf '#!/bin/sh\necho hdr\n' > "$D/claude/helper.sh"; chmod +x "$D/claude/helper.sh"
echo '{"a":1}' > "$D/vscode/settings.json"
echo '{"mcpServers":{"x":{}}}' > "$D/root/mcp.json"; echo "keys: []" > "$D/root/sops.yaml"   # per-repo file that must NOT be mirrored
cat > "$S/manifest.json" <<'J'
{"targets":{"claude":".claude","vscode":".vscode"},
 "root_targets":{"mcp.json":".mcp.json","sops.yaml":".sops.yaml"},
 "fleet":{"repos":[{"dir":"r-ok"},{"dir":"r-bad"},{"dir":"r-none"},{"dir":"r-ghost"},
   {"dir":"r-src","sources":{"prefix":"assets/cfg","map":{".mcp.json":"mcp.json",".claude":"claude"}}}],
          "root_files":["mcp.json"],
          "module_mirrors":[{"from":"root","to":"0_apps/src/root","only":["mcp.json"]}]}}
J
# r-ok: everything in sync
mkdir -p "$B/r-ok/.claude" "$B/r-ok/.vscode"
cp -p "$D/claude/helper.sh" "$B/r-ok/.claude/"; cp "$D/vscode/settings.json" "$B/r-ok/.vscode/"; cp "$D/root/mcp.json" "$B/r-ok/.mcp.json"
# r-bad: .mcp.json is a dangling symlink, .claude file drifted, .vscode absent, stale module copy
mkdir -p "$B/r-bad/.claude" "$B/r-bad/0_apps/src/root"
ln -s /home/nobody/.mcp.json "$B/r-bad/.mcp.json"
echo stale > "$B/r-bad/.claude/helper.sh"
echo '{"mcpServers":{}}' > "$B/r-bad/0_apps/src/root/mcp.json"
# r-none: bare repo (the cloud-data-my-ai-memory case) — no dotfiles, no module
mkdir -p "$B/r-none"
# r-ghost: not checked out at all
# r-src: generates its root dotfiles from assets/cfg (the cloud-data-my-ai-memory case) — sources are stale
mkdir -p "$B/r-src/assets/cfg/claude"; echo old > "$B/r-src/assets/cfg/mcp.json"; echo old > "$B/r-src/assets/cfg/claude/helper.sh"

run() { sh "$FLEET" "$@" "$S" "$D" "$B"; }

expect C1 1 'SYMLINK.*r-bad.*\.mcp\.json'            -- run --check
expect C2 1 'DRIFT.*r-bad.*\.claude/helper\.sh'      -- run --check
expect C3 1 'DRIFT.*r-bad.*0_apps/src/root/mcp\.json' -- run --check
expect C4 1 'MISSING.*r-none.*\.mcp\.json'           -- run --check
expect C4b 1 'MISSING.*r-src.*assets/cfg/claude/helper\.sh|DRIFT.*r-src.*assets/cfg/claude/helper\.sh' -- run --check
expect C4c 1 'DRIFT.*r-src.*assets/cfg/mcp\.json' -- run --check
expect C5 0 'ABSENT.*r-ghost' -- run
expect C5b 0 'fleet dotfiles: 4 repo\(s\) checked, 1 absent, 0 drifted' -- run --check
cmp -s "$D/root/mcp.json" "$B/r-src/assets/cfg/mcp.json" && cmp -s "$D/claude/helper.sh" "$B/r-src/assets/cfg/claude/helper.sh" && [ ! -e "$B/r-src/assets/cfg/vscode" ] && ok "C5c fleet files also land in the repo's own dotfile SOURCE (mapped paths only)" || bad "C5c source tree not updated"
[ ! -e "$B/r-none/0_apps" ] && ok "C6 module copy never created where the repo has no module" || bad "C6 created 0_apps in r-none"
[ -f "$B/r-bad/.mcp.json" ] && [ ! -L "$B/r-bad/.mcp.json" ] && cmp -s "$D/root/mcp.json" "$B/r-bad/.mcp.json" && ok "C7 symlink replaced by a real, identical file" || bad "C7 symlink not replaced"
[ ! -e "$B/r-bad/0_apps/src/root/sops.yaml" ] && ok "C6b per-repo sops.yaml is never mirrored (only: [mcp.json])" || bad "C6b sops.yaml leaked into a module copy"
[ -x "$B/r-none/.claude/helper.sh" ] && ok "C8 exec bit survives the emit" || bad "C8 exec bit lost"
expect C9 1 'FAIL: --require-all' -- run --require-all --check
echo '{"targets":{}}' > "$S/manifest.json"
expect C10 1 'no fleet.repos' -- run --check

# ── part 2: the real declaration ───────────────────────────────────────────
M="$ROOT/0_apps/src/manifest.json"
n=$(jq '.fleet.repos|length' "$M"); u=$(jq '[.fleet.repos[].dir]|unique|length' "$M")
[ "$n" -gt 1 ] && [ "$n" = "$u" ] && ok "R1 fleet lists $n distinct repos" || bad "R1 fleet repos missing/duplicated ($n/$u)"
missing=$(jq -r --slurpfile g "$ROOT/1_cloud-configs/src/inputs/github-repos.json" '[.fleet.repos[].github] - [$g[0].repos[].name] | join(",")' "$M")
[ -z "$missing" ] && ok "R2 every fleet repo exists on GitHub" || bad "R2 not on GitHub: $missing"
cmp -s "$ROOT/1_cloud-configs/dist/mcp.json" "$ROOT/0_apps/dist/dotfiles/root/mcp.json" && ok "R3 shipped .mcp.json IS the deriver's output" || bad "R3 0_apps/dist/dotfiles/root/mcp.json differs from 1_cloud-configs/dist/mcp.json — run build.sh dotfiles"
jq -e '.mcpServers|has("cloud-infra-mcp") and has("cloud-services-mcp") and (length>=11)' "$ROOT/0_apps/dist/dotfiles/root/mcp.json" >/dev/null && ok "R4 shipped .mcp.json has the full list incl. cloud-infra-mcp" || bad "R4 shipped .mcp.json lacks cloud-infra-mcp/cloud-services-mcp or has <11 servers"
[ -x "$ROOT/0_apps/dist/dotfiles/claude/mcp-auth-headers.sh" ] && ok "R5 the headersHelper ships with the dotfiles" || bad "R5 mcp-auth-headers.sh missing/not executable in dist"

# ── part 3: the real fleet ─────────────────────────────────────────────────
if [ "${GITHUB_ACTIONS:-}" = true ] || [ "${FLEET_LIVE:-}" = 1 ]; then
    if [ "${GITHUB_ACTIONS:-}" = true ]; then
        LIVE="$T/live"; sh "$ROOT/9_others/src/fetch-fleet-public.sh" "$M" "$LIVE" || bad "L0 fetch failed"
        args=""
    else
        LIVE="${CLOUD_GIT_BASE:-$HOME/git}"; args="--require-all"
    fi
    expect L1 0 'fleet dotfiles: [0-9]+ repo' -- sh "$FLEET" --check $args "$ROOT/0_apps/src" "$ROOT/0_apps/dist/dotfiles" "$LIVE"
else
    echo "SKIP L1 live fleet (set FLEET_LIVE=1, or run in CI)"
fi

echo "dotfiles-fleet: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
