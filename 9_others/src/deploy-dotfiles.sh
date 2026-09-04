#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ dotfiles deploy — src/dotfiles/<tool>/ → dist/ → <repo>/<target> ║
# ║                                                                  ║
# ║ Usage: deploy.sh <dotfiles-src-dir> <dist-dir> <repo-root>       ║
# ╚══════════════════════════════════════════════════════════════════╝
#
# THE single implementation, shared by every repo. cloud's richer
# 9_others/build.sh calls it as its `dotfiles` verb; repos without cloud's
# TypeScript engines ship a thin build.sh that calls exactly the same script.
# Duplicating this logic per repo is how the gitea mirror list drifted — one
# implementation, many callers.
#
# Plain POSIX sh + node (for JSON only). No repo-specific assumptions.
#
# node, not python3: node is already an unconditional dependency of every
# caller (the derive engines are TypeScript run through tsx), whereas python3
# is NOT installed in the cloud-builder image. gen-configs died here on
# 2026-08-10 with "python3: command not found" — and because the interpreter
# failure was swallowed by the `|| FATAL: invalid JSON` guard below, the error
# accused the data instead of naming the missing interpreter.
#
# Deploy is ADDITIVE PER FILE and never purges the target directory. Unlike
# 1_cicd/dist, the target dirs mix managed config with per-machine state:
#   .obsidian/workspace.json        pane ids + layout for ONE device
#   .claude/settings.local.json     documented place for local overrides
#   .claude/agents/                 may exist per-repo and is not ours
# A purge-then-copy would destroy all of that on every build. Files are copied
# individually so anything not named in src/ is left exactly as found.

set -e

DF_SRC="$1"
DF_DIST="$2"
REPO_ROOT="$3"

[ -n "$DF_SRC" ] && [ -n "$DF_DIST" ] && [ -n "$REPO_ROOT" ] || {
    echo "usage: deploy.sh <dotfiles-src-dir> <dist-dir> <repo-root>" >&2; exit 2; }

MANIFEST="$DF_SRC/manifest.json"
[ -d "$DF_SRC" ]   || { echo "no dotfiles src at $DF_SRC — nothing to do"; exit 0; }
[ -f "$MANIFEST" ] || { echo "FATAL: $MANIFEST missing" >&2; exit 1; }

log() { printf "[%s]   %s\n" "$(date '+%H:%M:%S')" "$1"; }

command -v node >/dev/null 2>&1 || {
    echo "FATAL: node not found — required to read $MANIFEST" >&2; exit 1; }

# Manifest readers live in one place so a missing interpreter can never again
# be reported as malformed data.
json_keys()   { node -e 'const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(Object.keys(m.targets||{}).join(" "))' "$1"; }
json_target() { node -e 'const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(m.targets[process.argv[2]]))' "$1" "$2"; }
json_root_keys()   { node -e 'const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(Object.keys(m.root_targets||{}).join(" "))' "$1"; }
json_root_target() { node -e 'const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(m.root_targets[process.argv[2]]))' "$1" "$2"; }
json_sot_source()  { node -e 'const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String((m.sot_sources||{})[process.argv[2]]||""))' "$1" "$2"; }

# Validate every source file BEFORE touching the working tree — a half-applied
# set of broken JSON is worse than not deploying at all.
for f in $(find "$DF_SRC" -maxdepth 2 -path '*app-*' -name '*.json'); do
    node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$f" \
        || { echo "FATAL: invalid JSON: $f" >&2; exit 1; }
done

rm -rf "$DF_DIST"
mkdir -p "$DF_DIST"

TOOLS=$(json_keys "$MANIFEST")
for tool in $TOOLS; do
    target=$(json_target "$MANIFEST" "$tool")
    if [ ! -d "$DF_SRC/$tool" ]; then
        log "dotfiles: no src for '$tool' — skipping"
        continue
    fi
    mkdir -p "$DF_DIST/$tool" "$REPO_ROOT/$target"

    # Refresh src/<tool>/ from its declared source of truth when one is
    # reachable. This is the root_targets refresh below, one level up, for the
    # same reason: a committed copy that nothing regenerates drifts, and drift
    # is invisible here because every copy's own _doc claims to be the shared
    # file. mcp-auth-headers.sh is the proof — the three copies in this repo
    # still named cloud-infra-mcp months after the rename to c3-infra-mcp,
    # while the copy actually deployed into the repos had the new name.
    #
    # BY NAME, and only names present on both sides. That is what keeps
    # settings.json out of it: a deliberate subset mirror of the
    # machine-independent half of settings.base.json, not a copy of any single
    # SoT file, and nothing in the SoT is named settings.json. Excluded by
    # construction rather than by a special case someone must remember to keep.
    #
    # No-op when the SoT is not checked out — the portable case. A repo with no
    # my-ai sibling keeps shipping its committed src/ copy unchanged.
    _sot_rel=$(json_sot_source "$MANIFEST" "$tool")
    if [ -n "$_sot_rel" ]; then
        for _sot_dir in "${CLAUDE_SOT_DIR:-}" "$REPO_ROOT/../cloud-u-linux/$_sot_rel"; do
            [ -n "$_sot_dir" ] && [ -d "$_sot_dir" ] || continue
            for _sf in "$_sot_dir"/*; do
                [ -f "$_sf" ] || continue
                _name=$(basename "$_sf")
                [ -f "$DF_SRC/$tool/$_name" ] || continue
                cmp -s "$_sf" "$DF_SRC/$tool/$_name" && continue
                cp -f "$_sf" "$DF_SRC/$tool/$_name"
                log "dotfiles: $tool/$_name refreshed from the SoT ($_sot_dir)"
            done
            break
        done
    fi
    # -r, so subdirectories come along. Without it `cp -f src/*` silently drops
    # every directory (the error is swallowed by `2>/dev/null || true`), which
    # is how .claude/agents/ deployed as nothing while the log still said
    # "claude -> .claude (1 files)" and looked fine.
    #
    # Still additive, never a purge: .claude/ and .obsidian/ mix managed config
    # with machine state (see never_manage), so the target is never emptied.
    cp -rf "$DF_SRC/$tool"/. "$DF_DIST/$tool"/ 2>/dev/null || true
    cp -rf "$DF_DIST/$tool"/. "$REPO_ROOT/$target"/ 2>/dev/null || true
    n=$(find "$DF_DIST/$tool" -type f 2>/dev/null | wc -l | tr -d ' ')
    log "dotfiles: $tool -> $target ($n files)"
done

# ── repo-root files ─────────────────────────────────────────────────────────
# Some agent config is a single file at the repo ROOT, not a directory:
# .mcp.json is the one that matters. cloud carried it as a symlink to
# /home/diego/.mcp.json, so every clone, CI runner and container got a dangling
# link — and Claude Code loads NO servers when .mcp.json is unreadable, without
# saying so. Shipping a real file per repo is what makes each one self-contained.
ROOT_FILES=$(json_root_keys "$MANIFEST")
for rf in $ROOT_FILES; do
    target=$(json_root_target "$MANIFEST" "$rf")
    src="$DF_SRC/root/$rf"

    # Refresh src/ from the derive output when this repo HAS a derive engine.
    #
    # mcp.json is generated by 1_cloud-configs/src/derive/derive-mcp-json.ts
    # into 1_cloud-configs/dist/. Nothing connected that to src/apps/root/, so
    # the file every repo ships was a hand-made copy, and "regenerate the
    # derive" did not change what got deployed. That is how .mcp.json in vault
    # ended up without the cloud-infra-mcp headersHelper while cloud's had it —
    # both claiming, in their own _doc, to be the same file.
    #
    # No-op in the other repos: they have no 1_cloud-configs/, so the guard
    # fails and the committed src/ copy is used unchanged. The module stays
    # portable (see manifest _portability).
    # sops.yaml lives in its own tier (2_sops/), not under apps/root/.
    [ "$rf" = "sops.yaml" ] && [ -f "$REPO_ROOT/2_sops/sops.yaml" ] && src="$REPO_ROOT/2_sops/sops.yaml"
    _derived="$REPO_ROOT/1_cloud-configs/dist/$rf"
    if [ -f "$_derived" ] && [ -f "$src" ] && ! cmp -s "$_derived" "$src"; then
        cp -f "$_derived" "$src"
        log "root: $rf refreshed from 1_cloud-configs/dist/ (derive is the source of truth)"
    fi

    [ -f "$src" ] || { log "root: no src for '$rf' — skipping"; continue; }
    mkdir -p "$DF_DIST/root"
    cp -f "$src" "$DF_DIST/root/$rf"
    # Replace a symlink outright rather than writing through it — the whole
    # point is to stop pointing at a machine-local path.
    [ -L "$REPO_ROOT/$target" ] && rm -f "$REPO_ROOT/$target"
    cp -f "$DF_DIST/root/$rf" "$REPO_ROOT/$target"
    log "root: $rf -> $target"
done

# Say out loud what was left alone, so "why isn't workspace.json in src/"
# never has to be rediscovered.
node -e '
const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const keep = m.never_manage || [];
if (keep.length) console.log("            preserved (machine state, never managed): " + keep.join(", "));
' "$MANIFEST"
