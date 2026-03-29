#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Workflow engine: build (src→dist) + deploy (dist→.github/)       ║
# ║                                                                  ║
# ║ Usage: ./build.sh              # build + deploy (default)        ║
# ║        ./build.sh build        # src → dist only                 ║
# ║        ./build.sh deploy       # dist → .github/ + repo root    ║
# ╚══════════════════════════════════════════════════════════════════╝
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
DIST_DIR="$SCRIPT_DIR/dist"
TARGET_DIR="$REPO_ROOT/.github/workflows"
SCRIPTS_TARGET="$TARGET_DIR/scripts"
HOOKS_TARGET="$TARGET_DIR/hooks"

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }

do_build() {
    mkdir -p "$DIST_DIR" "$DIST_DIR/scripts" "$DIST_DIR/hooks"

    # Static workflows (src/static/*.yml → dist/)
    rm -f "$DIST_DIR"/*.yml
    for f in "$SRC_DIR"/static/*.yml; do
        [ -f "$f" ] || continue
        cp "$f" "$DIST_DIR/"
    done
    log "Built $(ls "$DIST_DIR"/*.yml 2>/dev/null | wc -l) workflow(s)"

    # Scripts (src/scripts/ → dist/scripts/)
    if [ -d "$SRC_DIR/scripts" ]; then
        cp -r "$SRC_DIR/scripts/"* "$DIST_DIR/scripts/" 2>/dev/null || true
        chmod +x "$DIST_DIR/scripts/"*.sh 2>/dev/null || true
        log "Built scripts"
    fi

    # Hooks (src/hooks/ → dist/hooks/)
    if [ -d "$SRC_DIR/hooks" ]; then
        cp -r "$SRC_DIR/hooks/"* "$DIST_DIR/hooks/" 2>/dev/null || true
        chmod +x "$DIST_DIR/hooks/"*.sh 2>/dev/null || true
        log "Built hooks"
    fi

    # Gitmodules (src/gitmodules/ → dist/)
    if [ -d "$SRC_DIR/gitmodules" ]; then
        cp "$SRC_DIR/gitmodules/"* "$DIST_DIR/" 2>/dev/null || true
        log "Built gitmodules"
    fi

    # Gitconfig (src/gitconfig → dist/)
    if [ -f "$SRC_DIR/gitconfig" ]; then
        cp "$SRC_DIR/gitconfig" "$DIST_DIR/gitconfig"
        log "Built gitconfig"
    fi
}

do_deploy() {
    mkdir -p "$TARGET_DIR" "$SCRIPTS_TARGET" "$HOOKS_TARGET"

    # Workflows
    for f in "$DIST_DIR"/*.yml; do
        [ -f "$f" ] || continue
        cp "$f" "$TARGET_DIR/"
    done
    log "Deployed $(ls "$DIST_DIR"/*.yml 2>/dev/null | wc -l) workflow(s) → .github/workflows/"

    # Scripts
    if [ -d "$DIST_DIR/scripts" ]; then
        cp -r "$DIST_DIR/scripts/"* "$SCRIPTS_TARGET/" 2>/dev/null || true
        chmod +x "$SCRIPTS_TARGET/"*.sh 2>/dev/null || true
        log "Deployed scripts"
    fi

    # Hooks
    if [ -d "$DIST_DIR/hooks" ]; then
        cp -r "$DIST_DIR/hooks/"* "$HOOKS_TARGET/" 2>/dev/null || true
        chmod +x "$HOOKS_TARGET/"*.sh 2>/dev/null || true
        log "Deployed hooks"
    fi

    # Repo-root configs (.gitmodules etc)
    for f in "$DIST_DIR"/.git*; do
        [ -f "$f" ] || continue
        cp "$f" "$REPO_ROOT/"
        log "Deployed $(basename "$f") → repo root"
    done

    # Gitconfig → include in .git/config
    if [ -f "$DIST_DIR/gitconfig" ]; then
        git -C "$REPO_ROOT" config --local include.path ../workflows/dist/gitconfig 2>/dev/null || true
        log "Deployed gitconfig (included in .git/config)"
    fi

    log "Done"
}

case "${1:-all}" in
    build)   do_build ;;
    deploy)  do_deploy ;;
    all|"")  do_build; do_deploy ;;
    *)       echo "Usage: $0 [build|deploy|all]" ;;
esac
