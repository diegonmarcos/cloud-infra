#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ <repo>/2_configs — build + deploy this repo's dotfiles           ║
# ║                                                                  ║
# ║ Usage: ./build.sh [all|dotfiles|clean]                           ║
# ╚══════════════════════════════════════════════════════════════════╝
#
# Thin wrapper. All logic lives in src/dotfiles/deploy.sh, which is the SAME
# script cloud/2_configs/build.sh calls — one implementation, many repos.
# To update the behaviour everywhere, change deploy.sh in cloud and re-sync.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST="$SCRIPT_DIR/dist"

dotfiles() {
    sh "$SCRIPT_DIR/src/dotfiles/deploy.sh" \
       "$SCRIPT_DIR/src/dotfiles" "$DIST/dotfiles" "$REPO_ROOT"
}

clean() { rm -rf "$DIST"; echo "cleaned $DIST"; }

case "${1:-all}" in
    all|dotfiles) dotfiles ;;
    clean)        clean ;;
    *) echo "Usage: $0 [all|dotfiles|clean]" >&2; exit 1 ;;
esac
