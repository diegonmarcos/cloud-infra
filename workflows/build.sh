#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Deploy workflows from dist/ to .github/workflows/               ║
# ║                                                                  ║
# ║ Usage: ./build.sh deploy                                         ║
# ╚══════════════════════════════════════════════════════════════════╝
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"
TARGET_DIR="$REPO_ROOT/.github/workflows"
SCRIPTS_TARGET="$TARGET_DIR/scripts"
HOOKS_TARGET="$TARGET_DIR/hooks"

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }

case "${1:-deploy}" in
    deploy)
        mkdir -p "$TARGET_DIR" "$SCRIPTS_TARGET" "$HOOKS_TARGET"

        # Copy workflow YMLs
        for f in "$DIST_DIR"/*.yml; do
            [ -f "$f" ] || continue
            cp "$f" "$TARGET_DIR/"
        done
        log "Deployed $(ls "$DIST_DIR"/*.yml 2>/dev/null | wc -l) workflow(s) → .github/workflows/"

        # Copy scripts
        if [ -d "$DIST_DIR/scripts" ]; then
            cp -r "$DIST_DIR/scripts/"* "$SCRIPTS_TARGET/"
            chmod +x "$SCRIPTS_TARGET/"*.sh 2>/dev/null || true
            log "Deployed scripts → .github/workflows/scripts/"
        fi

        # Copy hooks
        if [ -d "$DIST_DIR/hooks" ]; then
            cp -r "$DIST_DIR/hooks/"* "$HOOKS_TARGET/"
            chmod +x "$HOOKS_TARGET/"*.sh 2>/dev/null || true
            log "Deployed hooks → .github/workflows/hooks/"
        fi

        log "Done"
        ;;
    *)
        echo "Usage: $0 [deploy]"
        ;;
esac
