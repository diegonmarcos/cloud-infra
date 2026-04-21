#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ cloud/4_reports — manifest regenerator                           ║
# ║                                                                   ║
# ║ 4_reports/dist/ is a symlink into the cloud-data submodule; its  ║
# ║ reports are built by cloud-data's reports engine. This script    ║
# ║ scans 4_reports/dist/*.md and emits 4_reports/manifest.json       ║
# ║ with dashboard-friendly paths (dist/foo.md, not reports/dist/...) ║
# ║                                                                   ║
# ║ Usage: ./build.sh [manifest|all]                                  ║
# ╚══════════════════════════════════════════════════════════════════╝
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST="$SCRIPT_DIR/dist"
MANIFEST="$SCRIPT_DIR/manifest.json"

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }

generate_manifest() {
    # Source of truth is cloud-data/reports/manifest.json (produced by
    # cloud-data's reports engine). Transform its paths from
    # 'reports/dist/foo.md' → 'dist/foo.md' for the cloud/ dashboard.
    UPSTREAM="$(cd "$SCRIPT_DIR/../.." && pwd)/cloud-data/reports/manifest.json"
    if [ ! -f "$UPSTREAM" ]; then
        log "upstream manifest not found ($UPSTREAM) — emitting empty"
        printf '[]\n' > "$MANIFEST"
        return 0
    fi
    if ! command -v jq >/dev/null 2>&1; then
        log "jq not in PATH — copying upstream verbatim"
        cp "$UPSTREAM" "$MANIFEST"
        return 0
    fi
    jq 'map({file: (.file | sub("^reports/"; "")), name: .name})' "$UPSTREAM" > "$MANIFEST"
    log "Regenerated manifest.json from upstream ($(jq length "$MANIFEST") entries)"
}

case "${1:-manifest}" in
    manifest|all) generate_manifest ;;
    *) echo "Usage: $0 [manifest|all]"; exit 1 ;;
esac
