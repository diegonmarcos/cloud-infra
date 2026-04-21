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
BUILDS="$SCRIPT_DIR/src/builds"
DIST="$SCRIPT_DIR/dist"
CLOUD_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOLUTIONS_DIR="$CLOUD_ROOT/a_solutions"

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }

# Mirror every a_solutions/<folder>/build.json as
# 2_configs/src/builds/build-<folder>.json (symlink). Declarative index —
# one place to list every service's raw build.json.
link_builds() {
    mkdir -p "$BUILDS"
    # Drop stale build-*.json symlinks first
    command find "$BUILDS" -maxdepth 1 -name 'build-*.json' -type l -delete 2>/dev/null
    count=0
    for svc in "$SOLUTIONS_DIR"/*/; do
        [ -d "$svc" ] || continue
        folder=$(basename "$svc")
        bj="$svc/build.json"
        [ -f "$bj" ] || [ -L "$bj" ] || continue
        ln -s "../../../a_solutions/$folder/build.json" "$BUILDS/build-$folder.json"
        count=$((count + 1))
    done
    log "Linked $count a_solutions/*/build.json → src/builds/build-{folder}.json"
}

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
    link-builds) link_builds ;;
    consolidate) consolidate ;;
    derive)      derive ;;
    test)        run_tests ;;
    clean)       clean ;;
    all)         link_builds; consolidate; derive ;;
    ship)        link_builds; consolidate; derive; run_tests ;;
    *)           echo "Usage: $0 [all|link-builds|consolidate|derive|test|clean|ship]"; exit 1 ;;
esac
