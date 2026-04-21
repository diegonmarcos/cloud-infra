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
    # Walk cloud-data/reports/dist/ directly for every *.md and *.html
    # (upstream reports/manifest.json only lists .md — we include .html too).
    UPSTREAM_DIST="$(cd "$SCRIPT_DIR/../.." && pwd)/cloud-data/reports/dist"
    if [ ! -d "$UPSTREAM_DIST" ]; then
        log "upstream dist not found ($UPSTREAM_DIST) — emitting empty"
        printf '[]\n' > "$MANIFEST"
        return 0
    fi
    printf '[\n' > "$MANIFEST"
    first=true
    for f in "$UPSTREAM_DIST"/*.md "$UPSTREAM_DIST"/*.html; do
        [ -f "$f" ] || continue
        base=$(basename "$f")
        name=$(basename "$base" | sed -E 's/\.(md|html)$//' | tr '_' ' ')
        ext="${base##*.}"
        # Tag html entries with (HTML) so the dashboard distinguishes formats
        case "$ext" in
            html) name="$name (HTML)" ;;
        esac
        file="dist/$base"
        if [ "$first" = true ]; then first=false; else printf ',\n' >> "$MANIFEST"; fi
        printf '  {"file": "%s", "name": "%s"}' "$file" "$name" >> "$MANIFEST"
    done
    printf '\n]\n' >> "$MANIFEST"
    log "Regenerated manifest.json ($(command grep -c '{"file' "$MANIFEST") entries: .md + .html)"
}

case "${1:-manifest}" in
    manifest|all) generate_manifest ;;
    *) echo "Usage: $0 [manifest|all]"; exit 1 ;;
esac
