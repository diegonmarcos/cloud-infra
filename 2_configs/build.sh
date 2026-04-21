#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ cloud/2_configs — consolidate + derive every cloud-data JSON    ║
# ║                                                                  ║
# ║ Reads: cloud/a_solutions/*/build.json, cloud/config.json,       ║
# ║        cloud/b_infra/home-manager/*/build.json, vault/**        ║
# ║ Writes: cloud/2_configs/dist/*.json                             ║
# ║                                                                  ║
# ║ Usage: ./build.sh [all|consolidate|derive|test|clean]           ║
# ╚══════════════════════════════════════════════════════════════════╝
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINES="$SCRIPT_DIR/src/engines"
DIST="$SCRIPT_DIR/dist"

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }

consolidate() {
    mkdir -p "$DIST"
    log "Consolidating → $DIST/_cloud-data-consolidated.json"
    tsx "$ENGINES/cloud-data-config-consolidated.ts"
}

derive() {
    mkdir -p "$DIST"
    log "Deriving per-concern + per-container JSONs → $DIST/"
    tsx "$ENGINES/cloud-data-config-derive.ts"
}

run_tests() {
    [ -f "$ENGINES/test-build-per-container.sh" ] || return 0
    log "Running tests..."
    fails=0
    for t in "$ENGINES/"test-*.sh; do
        [ -f "$t" ] || continue
        bash "$t" || fails=$((fails + 1))
    done
    [ $fails -eq 0 ] || { log "Tests failed: $fails"; exit 1; }
    log "All tests passed"
}

clean() {
    rm -rf "$DIST"
    log "Cleaned $DIST"
}

case "${1:-all}" in
    consolidate) consolidate ;;
    derive)      derive ;;
    test)        run_tests ;;
    clean)       clean ;;
    all)         consolidate; derive ;;
    ship)        consolidate; derive; run_tests ;;
    *)           echo "Usage: $0 [all|consolidate|derive|test|clean|ship]"; exit 1 ;;
esac
