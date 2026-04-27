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

# ══════════════════════════════════════════════════════════════════════
# ensure_node_deps — self-bootstrap engines' node toolchain
# ══════════════════════════════════════════════════════════════════════
# 2_configs/ TypeScript engines (consolidate, derive) are run via tsx and
# import yaml + nunjucks. On hosts without the cloud-builder image (bare
# GHA runners, fresh clones, dev laptops), these aren't installed. This
# function checks PATH for tsx; if missing, installs config.json:
# .deps.node.required at $CLOUD_ROOT/node_modules and prepends
# $CLOUD_ROOT/node_modules/.bin to PATH so tsx is found AND yaml/nunjucks
# resolve via normal node_modules walk-up from any subdir.
#
# Surfaced 2026-04-27 across multiple ship runs (25011200839, 25013604449,
# 25014061872): tsx not found, yaml ESM resolution failed. Fix lives in
# the engine itself, not in every workflow that calls it (FIRE rule 1:
# "Always fix the engine — never bypass with one-liners").
ensure_node_deps() {
    if command -v tsx >/dev/null 2>&1; then
        return 0
    fi
    if [ -x "$CLOUD_ROOT/node_modules/.bin/tsx" ]; then
        export PATH="$CLOUD_ROOT/node_modules/.bin:$PATH"
        return 0
    fi
    log "ensure_node_deps: tsx not on PATH — bootstrapping engine deps"
    if ! command -v npm >/dev/null 2>&1; then
        log "ensure_node_deps: ERROR npm not found — node 18+ required on host"
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        log "ensure_node_deps: ERROR jq not found — required to read config.json"
        return 1
    fi
    PKGS=$(jq -r '.deps.node.required[]?' "$CLOUD_ROOT/config.json" 2>/dev/null | tr '\n' ' ')
    # Fallback mirrors config.json:.deps.node.required so a stale config.json
    # (missing ajv/ajv-formats) still gets all engine deps installed.
    [ -z "$PKGS" ] && PKGS="tsx yaml nunjucks ajv ajv-formats"
    (
        cd "$CLOUD_ROOT" && npm install --silent --no-save $PKGS
    ) || {
        log "ensure_node_deps: ERROR npm install failed (PKGS=$PKGS)"
        return 1
    }
    export PATH="$CLOUD_ROOT/node_modules/.bin:$PATH"
    log "ensure_node_deps: bootstrapped $PKGS at $CLOUD_ROOT/node_modules"
}

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
    ensure_node_deps
    mkdir -p "$DIST"
    log "Consolidating → $DIST/_cloud-data-consolidated.json"
    tsx "$ENGINES/cloud-data-config-consolidated.ts"
}

derive() {
    ensure_node_deps
    mkdir -p "$DIST"
    log "Deriving per-concern + per-container JSONs → $DIST/"
    tsx "$ENGINES/cloud-data-config-derive.ts"
    cache_download_generator
}

# ══════════════════════════════════════════════════════════════════════
# cache_download_generator — engines-ship cache step
# ══════════════════════════════════════════════════════════════════════
# Pulls hand-edited / externally-cached fixtures from the cloud-data
# submodule into dist/. Acts like the "secrets" step (sops decryption →
# dist/.secrets) but for cached/static data files rather than encrypted
# secrets — the engine treats both as inputs the build pipeline must
# materialise into dist/ before downstream consumers (image build,
# deploy) can run.
#
# Source preference: sibling clone (live edits) → in-repo submodule
# (committed). Each entry can declare its own source if needed.
cache_download_generator() {
    for f in cloud-data-runners.json; do
        for _srcdir in "$CLOUD_ROOT/../cloud-data" "$CLOUD_ROOT/I_cloud-data"; do
            _src="$_srcdir/$f"
            if [ -f "$_src" ]; then
                cp -f "$_src" "$DIST/$f"
                log "cache_download_generator: $f ← $_srcdir"
                break
            fi
        done
    done
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
