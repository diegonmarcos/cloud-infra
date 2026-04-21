#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ cloud/3_secrets — aggregated secrets index                      ║
# ║                                                                  ║
# ║ Symlinks every a_solutions/<folder>/src/secrets.yaml as         ║
# ║   <folder>-secrets.yaml                                         ║
# ║ Single-pane view of every sops-encrypted service secret.       ║
# ║                                                                  ║
# ║ Usage: ./build.sh [link|clean]                                  ║
# ╚══════════════════════════════════════════════════════════════════╝
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLOUD_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOLUTIONS_DIR="$CLOUD_ROOT/a_solutions"

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }

link_secrets() {
    # Drop stale <folder>-secrets.yaml symlinks
    command find "$SCRIPT_DIR" -maxdepth 1 -name '*-secrets.yaml' -type l -delete 2>/dev/null
    count=0
    for svc in "$SOLUTIONS_DIR"/*/; do
        [ -d "$svc" ] || continue
        folder=$(basename "$svc")
        sec="$svc/src/secrets.yaml"
        [ -f "$sec" ] || continue
        ln -s "../a_solutions/$folder/src/secrets.yaml" "$SCRIPT_DIR/$folder-secrets.yaml"
        count=$((count + 1))
    done
    log "Linked $count secrets.yaml → $SCRIPT_DIR/{folder}-secrets.yaml"
}

clean() {
    command find "$SCRIPT_DIR" -maxdepth 1 -name '*-secrets.yaml' -type l -delete
    log "Cleaned $SCRIPT_DIR/*-secrets.yaml symlinks"
}

case "${1:-link}" in
    link)  link_secrets ;;
    clean) clean ;;
    *)     echo "Usage: $0 [link|clean]"; exit 1 ;;
esac
