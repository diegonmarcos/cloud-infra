#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ cloud/2_configs — consolidate + derive every cloud-data JSON    ║
# ║                                                                  ║
# ║ Reads: cloud/a_solutions/*/build.json, cloud/config.json,       ║
# ║        cloud/b_infra/*/build.json, vault/**        ║
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
export CLOUD_ROOT  # cloud-paths.sh / ensure-deps.sh read this

# Emitters now write empty strings for `_generated` / `generated_at` (see
# 2_configs/src/engines/cloud-data-config-derive.ts:`now`). No timestamp env
# var needed — the SOURCE_DATE_EPOCH approach broke because pre-commit hooks
# run BEFORE the commit object exists, so HEAD's timestamp belongs to the
# PARENT commit, changing every push.

# Source shared engine libs (idempotent, guard against double-source).
LIB_DIR="$CLOUD_ROOT/1_workflows/src/libs"
# shellcheck source=../1_workflows/src/libs/engine-traps.sh
[ -f "$LIB_DIR/engine-traps.sh" ] && . "$LIB_DIR/engine-traps.sh"
# shellcheck source=../1_workflows/src/libs/cloud-paths.sh
[ -f "$LIB_DIR/cloud-paths.sh" ] && . "$LIB_DIR/cloud-paths.sh"
# shellcheck source=../1_workflows/src/libs/ensure-deps.sh
[ -f "$LIB_DIR/ensure-deps.sh" ] && . "$LIB_DIR/ensure-deps.sh"

# log defined by engine-traps.sh; define a fallback if libs are unavailable
# (e.g. running this script before the libs are deployed in someone's
# checkout — defensive, lib loading is the happy path).
if ! command -v log >/dev/null 2>&1; then
    log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }
fi

# ensure_node_deps now lives in 1_workflows/src/libs/ensure-deps.sh
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
# now lives in 1_workflows/build.json and is materialised by the
# build-workflows deriver (registered in src/derivers.json). This loop
# stays as a no-op stub so future cached fixtures can be re-added without
# touching the pipeline shape.
cache_download_generator() {
    : # currently no cached fixtures — kept as extension point
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


# ── dotfiles ────────────────────────────────────────────────────────────────
# src/dotfiles/<tool>/ → dist/dotfiles/<tool>/ → <repo>/<target>/
#
# Same src→dist→deploy shape as 1_workflows, with one deliberate difference:
# the target directory is NEVER purged. .claude/ and .obsidian/ mix managed
# config with per-machine state (pane layout, local permission overrides), so
# a purge-then-copy would clobber another device's state on every build. See
# src/dotfiles/manifest.json:never_manage.
#
# Portable by design: plain file copying, no dependency on this repo's TS
# engines, so the whole module can be copied into any repo as-is.
dotfiles() {
    sh "$SCRIPT_DIR/src/dotfiles/deploy.sh" \
       "$SCRIPT_DIR/src/dotfiles" "$DIST/dotfiles" "$CLOUD_ROOT"
}

case "${1:-all}" in
    link-builds) link_builds ;;
    consolidate) consolidate ;;
    derive)      derive ;;
    test)        run_tests ;;
    dotfiles)    dotfiles ;;
    clean)       clean ;;
    all)         link_builds; consolidate; derive; dotfiles ;;
    ship)        link_builds; consolidate; derive; dotfiles; run_tests ;;
    *)           echo "Usage: $0 [all|link-builds|consolidate|derive|dotfiles|test|clean|ship]"; exit 1 ;;
esac
