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
    # Clean dist/ first so deletions in src/ propagate (otherwise orphaned
    # scripts/hooks linger forever, including broken symlinks).
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR" "$DIST_DIR/scripts" "$DIST_DIR/hooks" "$DIST_DIR/test"

    # Static workflows (src/cicd/*.yml → dist/)
    rm -f "$DIST_DIR"/*.yml
    for f in "$SRC_DIR"/cicd/*.yml; do
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

    # Tests (src/test/ → dist/test/) — preflight testers invoked by ship-ci-image.yml
    if [ -d "$SRC_DIR/test" ]; then
        cp -r "$SRC_DIR/test/"* "$DIST_DIR/test/" 2>/dev/null || true
        chmod +x "$DIST_DIR/test/"*.sh 2>/dev/null || true
        log "Built tests"
    fi

    # Gitmodules (src/modules/gitmodules → dist/.gitmodules)
    if [ -f "$SRC_DIR/modules/gitmodules" ]; then
        cp "$SRC_DIR/modules/gitmodules" "$DIST_DIR/.gitmodules" 2>/dev/null || true
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

    # Sync submodules: ensure all entries in .gitmodules are registered + cloned
    if [ -f "$REPO_ROOT/.gitmodules" ]; then
        # Read declared submodules from .gitmodules
        git -C "$REPO_ROOT" config --file .gitmodules --get-regexp 'submodule\..*\.path' 2>/dev/null | while read -r key path; do
            name=$(echo "$key" | sed 's/^submodule\.\(.*\)\.path$/\1/')
            url=$(git -C "$REPO_ROOT" config --file .gitmodules "submodule.$name.url" 2>/dev/null || true)
            # Check if submodule is already in git index
            if git -C "$REPO_ROOT" ls-files --stage "$path" 2>/dev/null | grep -q '^160000'; then
                log "submodule '$name' already registered"
            else
                # New submodule: add it (this registers gitlink + clones)
                log "submodule '$name' not in index — adding from .gitmodules"
                git -C "$REPO_ROOT" submodule add --force --name "$name" "$url" "$path" 2>&1 | while IFS= read -r line; do
                    log "  $line"
                done
            fi
        done
        # Sync URLs + update all
        git -C "$REPO_ROOT" submodule sync 2>/dev/null || true
        git -C "$REPO_ROOT" submodule update --init 2>&1 | while IFS= read -r line; do
            log "submodule: $line"
        done
        log "Synced submodules"
    fi

    # Gitconfig → include in .git/config
    if [ -f "$DIST_DIR/gitconfig" ]; then
        git -C "$REPO_ROOT" config --local include.path ../1_workflows/dist/gitconfig 2>/dev/null || true
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
