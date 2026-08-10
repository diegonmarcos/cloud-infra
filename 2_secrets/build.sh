#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ cloud/2_secrets — aggregated secrets engine                      ║
# ║                                                                   ║
# ║ sync:    collect every a_solutions/*/src/secrets*.yaml            ║
# ║          + b_infra/**/secrets*.yaml → src/builds/                 ║
# ║ decrypt: sops -d src/builds/*.yaml → dist/*.secrets +             ║
# ║          dist/*.json.secrets + dist/cloud-secrets.json.secrets    ║
# ║ all:     sync + decrypt                                            ║
# ║                                                                   ║
# ║ Usage: ./build.sh [all|sync|decrypt|clean]                        ║
# ╚══════════════════════════════════════════════════════════════════╝
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$SCRIPT_DIR/src/engines/secrets.sh"
DIST="$SCRIPT_DIR/dist"
BUILDS="$SCRIPT_DIR/src/builds"

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }

case "${1:-all}" in
    sync)    "$ENGINE" sync "${2:-}" ;;
    decrypt) "$ENGINE" decrypt ;;
    all|ship)"$ENGINE" all "${2:-}" ;;
    clean)   rm -rf "$DIST"/* "$BUILDS"/*.yaml; log "Cleaned dist/ and src/builds/" ;;
    *)       echo "Usage: $0 [all|sync|decrypt|clean]"; exit 1 ;;
esac
