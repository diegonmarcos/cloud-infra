#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ cloud/1_cloud-configs — consolidate + derive every fleet JSON     ║
# ║                                                                  ║
# ║ Reads:  a_solutions/*/build.json, b_infra/*/build.json,          ║
# ║         config.json, vault/**, src/inputs/**                     ║
# ║ Writes: 1_cloud-configs/dist/*.json                              ║
# ║                                                                  ║
# ║ Usage: ./build.sh [all|link-builds|consolidate|derive|test|clean]║
# ╚══════════════════════════════════════════════════════════════════╝
#
# This module is the derive job and nothing else. No git config, no GHA
# workflows, no dotfiles — those are 1_configs, which every repo carries.
# The only thing here that is not a pure input→output transform is the
# shared shell libs it sources from 1_configs/src/lib (see LIB_DIR below):
# 1_cloud-configs depends on 1_configs, never the reverse.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINES="$SCRIPT_DIR/src/derive"
BUILDS="$SCRIPT_DIR/src/inputs/builds"
DIST="$SCRIPT_DIR/dist"
CLOUD_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOLUTIONS_DIR="$CLOUD_ROOT/a_solutions"
export CLOUD_ROOT  # cloud-paths.sh / ensure-deps.sh read this

# Emitters now write empty strings for `_generated` / `generated_at` (see
# 1_cloud-configs/src/derive/cloud-data-config-derive.ts:`now`). No timestamp env
# var needed — the SOURCE_DATE_EPOCH approach broke because pre-commit hooks
# run BEFORE the commit object exists, so HEAD's timestamp belongs to the
# PARENT commit, changing every push.

# Source shared engine libs (idempotent, guard against double-source).
LIB_DIR="$CLOUD_ROOT/1_configs/src/lib"
# shellcheck source=../1_configs/src/lib/engine-traps.sh
[ -f "$LIB_DIR/engine-traps.sh" ] && . "$LIB_DIR/engine-traps.sh"
# shellcheck source=../1_configs/src/lib/cloud-paths.sh
[ -f "$LIB_DIR/cloud-paths.sh" ] && . "$LIB_DIR/cloud-paths.sh"
# shellcheck source=../1_configs/src/lib/ensure-deps.sh
[ -f "$LIB_DIR/ensure-deps.sh" ] && . "$LIB_DIR/ensure-deps.sh"

# log defined by engine-traps.sh; define a fallback if libs are unavailable
# (e.g. running this script before the libs are deployed in someone's
# checkout — defensive, lib loading is the happy path).
if ! command -v log >/dev/null 2>&1; then
    log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }
fi

# ensure_node_deps now lives in 1_configs/src/lib/ensure-deps.sh
# (sourced above). Define a thin local fallback so this script still
# works on a fresh clone where libs/ might not yet be deployed.
if ! command -v ensure_node_deps >/dev/null 2>&1; then
    ensure_node_deps() {
        if command -v tsx >/dev/null 2>&1; then return 0; fi
        if [ -x "$CLOUD_ROOT/node_modules/.bin/tsx" ]; then
            export PATH="$CLOUD_ROOT/node_modules/.bin:$PATH"; return 0
        fi
        if ! command -v npm >/dev/null 2>&1; then
            log "ensure_node_deps: ERROR npm not found"; return 1
        fi
        log "ensure_node_deps (fallback): bootstrapping engine deps"
        PKGS=""
        if [ -f "$CLOUD_ROOT/config.json" ] && command -v jq >/dev/null 2>&1; then
            PKGS=$(jq -r '.deps.node.required[]?' "$CLOUD_ROOT/config.json" 2>/dev/null | tr '\n' ' ')
        fi
        [ -z "$PKGS" ] && PKGS="tsx yaml nunjucks ajv ajv-formats"
        (cd "$CLOUD_ROOT" && npm install --silent --no-save $PKGS) || return 1
        export PATH="$CLOUD_ROOT/node_modules/.bin:$PATH"
    }
fi

# Mirror every a_solutions/<folder>/build.json as
# 1_cloud-configs/src/inputs/builds/build-<folder>.json (symlink). Declarative index —
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
        # Depth derived from $BUILDS, not hardcoded: this directory moved from
        # src/builds to src/inputs/builds and a literal ../../../ silently
        # produced 73 dangling links that only a broken-symlink sweep caught.
        rel=$(command realpath --relative-to="$BUILDS" "$SOLUTIONS_DIR/$folder/build.json" 2>/dev/null) \
            || rel="$CLOUD_ROOT/a_solutions/$folder/build.json"
        ln -s "$rel" "$BUILDS/build-$folder.json"
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
    DERIVERS_JSON="$SCRIPT_DIR/src/derivers.json"
    if [ -f "$DERIVERS_JSON" ] && command -v jq >/dev/null 2>&1; then
        count=$(jq '.derivers | length' "$DERIVERS_JSON")
        log "Deriving via $count derivers from src/derivers.json → $DIST/"
        i=0
        while [ "$i" -lt "$count" ]; do
            name=$(jq -r ".derivers[$i].name"   "$DERIVERS_JSON")
            rel=$( jq -r ".derivers[$i].script" "$DERIVERS_JSON")
            [ -f "$SCRIPT_DIR/$rel" ] || { log "ERROR: deriver '$name' script missing: $rel"; exit 1; }
            log "  → $name ($rel)"
            tsx "$SCRIPT_DIR/$rel" || { log "FAILED: deriver '$name'"; exit 1; }
            i=$((i + 1))
        done
    else
        # Fallback when jq is unavailable or the JSON hasn't been deployed yet —
        # keep the canonical deriver running so the pipeline never silently
        # produces an incomplete dist/. New derivers MUST be added to
        # derivers.json, not here.
        log "WARN: derivers.json or jq unavailable — running only the canonical cloud-data-config-derive.ts"
        tsx "$ENGINES/cloud-data-config-derive.ts"
    fi
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
#
# 2026-05-09: cloud-data-runners.json migrated out — runner-image registry
# now lives in 1_cloud-configs/build.json and is materialised by the
# build-workflows deriver (registered in src/derivers.json). This loop
# stays as a no-op stub so future cached fixtures can be re-added without
# touching the pipeline shape.
cache_download_generator() {
    : # currently no cached fixtures — kept as extension point
}

run_tests() {
    TESTS="$SCRIPT_DIR/src/test"
    [ -d "$TESTS" ] || return 0
    log "Running tests..."
    fails=0
    for t in "$TESTS/"test-*.sh; do
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
