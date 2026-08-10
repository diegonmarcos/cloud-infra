#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ dotfiles deploy — src/dotfiles/<tool>/ → dist/ → <repo>/<target> ║
# ║                                                                  ║
# ║ Usage: deploy.sh <dotfiles-src-dir> <dist-dir> <repo-root>       ║
# ╚══════════════════════════════════════════════════════════════════╝
#
# THE single implementation, shared by every repo. cloud's richer
# 1_configs/build.sh calls it as its `dotfiles` verb; repos without cloud's
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
# 1_configs/dist, the target dirs mix managed config with per-machine state:
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
    cp -f "$DF_SRC/$tool"/* "$DF_DIST/$tool"/ 2>/dev/null || true
    cp -f "$DF_DIST/$tool"/* "$REPO_ROOT/$target"/ 2>/dev/null || true
    n=$(ls -1 "$DF_DIST/$tool" 2>/dev/null | wc -l | tr -d ' ')
    log "dotfiles: $tool -> $target ($n files)"
done

# Say out loud what was left alone, so "why isn't workspace.json in src/"
# never has to be rediscovered.
node -e '
const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const keep = m.never_manage || [];
if (keep.length) console.log("            preserved (machine state, never managed): " + keep.join(", "));
' "$MANIFEST"
