#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ dotfiles deploy — src/dotfiles/<tool>/ → dist/ → <repo>/<target> ║
# ║                                                                  ║
# ║ Usage: deploy.sh <dotfiles-src-dir> <dist-dir> <repo-root>       ║
# ╚══════════════════════════════════════════════════════════════════╝
#
# THE single implementation, shared by every repo. cloud's richer
# 2_configs/build.sh calls it as its `dotfiles` verb; repos without cloud's
# TypeScript engines ship a thin build.sh that calls exactly the same script.
# Duplicating this logic per repo is how the gitea mirror list drifted — one
# implementation, many callers.
#
# Plain POSIX sh + python3 (for JSON only). No repo-specific assumptions.
#
# Deploy is ADDITIVE PER FILE and never purges the target directory. Unlike
# 1_workflows/dist, the target dirs mix managed config with per-machine state:
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

# Validate every source file BEFORE touching the working tree — a half-applied
# set of broken JSON is worse than not deploying at all.
for f in $(find "$DF_SRC" -name '*.json'); do
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f" \
        || { echo "FATAL: invalid JSON: $f" >&2; exit 1; }
done

rm -rf "$DF_DIST"
mkdir -p "$DF_DIST"

TOOLS=$(python3 -c "import json;print(' '.join(json.load(open('$MANIFEST'))['targets']))")
for tool in $TOOLS; do
    target=$(python3 -c "import json;print(json.load(open('$MANIFEST'))['targets']['$tool'])")
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
python3 - "$MANIFEST" <<'PYEOF'
import json, sys
m = json.load(open(sys.argv[1]))
keep = m.get("never_manage", [])
if keep:
    print("            preserved (machine state, never managed): " + ", ".join(keep))
PYEOF
