#!/usr/bin/env bash
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

# Shared lib: stamps every dist/ artifact with the GENERATED-FILE banner.
# Template + prefix map live in $SRC_DIR/libs/generated-header.json.
export REPO_ROOT
export ENGINE_NAME="1_workflows/src/scripts/cloud-ship-repo-workflow-engine.sh"
# shellcheck source=../libs/inject-header.sh
. "$SRC_DIR/libs/inject-header.sh"

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }

do_build() {
    # Clean dist/ first so deletions in src/ propagate (otherwise orphaned
    # scripts/hooks linger forever, including broken symlinks).
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR" "$DIST_DIR/scripts" "$DIST_DIR/hooks" "$DIST_DIR/test"

    # Static workflows (src/cicd/*.yml → dist/)
    for f in "$SRC_DIR"/cicd/*.yml; do
        [ -f "$f" ] || continue
        inject_header "$f" "$DIST_DIR/$(basename "$f")"
    done
    log "Built $(ls "$DIST_DIR"/*.yml 2>/dev/null | wc -l) workflow(s)"

    # Scripts (src/scripts/ → dist/scripts/)
    if [ -d "$SRC_DIR/scripts" ]; then
        inject_header_tree "$SRC_DIR/scripts" "$DIST_DIR/scripts"
        log "Built scripts"
    fi

    # Hooks (src/hooks/ → dist/hooks/)
    if [ -d "$SRC_DIR/hooks" ]; then
        inject_header_tree "$SRC_DIR/hooks" "$DIST_DIR/hooks"
        log "Built hooks"
    fi

    # Tests (src/test/ → dist/test/) — preflight testers invoked by ship-ci-image.yml
    if [ -d "$SRC_DIR/test" ]; then
        inject_header_tree "$SRC_DIR/test" "$DIST_DIR/test"
        log "Built tests"
    fi

    # Gitmodules (src/modules/gitmodules → dist/.gitmodules)
    if [ -f "$SRC_DIR/modules/gitmodules" ]; then
        inject_header "$SRC_DIR/modules/gitmodules" "$DIST_DIR/.gitmodules"
        log "Built gitmodules"
    fi

    # Gitignore (src/gitignore → dist/.gitignore)
    if [ -f "$SRC_DIR/gitignore" ]; then
        inject_header "$SRC_DIR/gitignore" "$DIST_DIR/.gitignore"
        log "Built gitignore"
    fi

    # Gitconfig (src/gitconfig → dist/)
    if [ -f "$SRC_DIR/gitconfig" ]; then
        inject_header "$SRC_DIR/gitconfig" "$DIST_DIR/gitconfig"
        log "Built gitconfig"
    fi

    # GHA actions (src/actions/ → dist/actions/)
    if [ -d "$SRC_DIR/actions" ]; then
        inject_header_tree "$SRC_DIR/actions" "$DIST_DIR/actions"
        log "Built actions"
    fi

    # GHA flake (src/flake.nix, src/flake.lock → dist/)
    # flake.lock is in skip_basenames (inject-header.sh) → copied verbatim.
    if [ -f "$SRC_DIR/flake.nix" ]; then
        inject_header "$SRC_DIR/flake.nix" "$DIST_DIR/flake.nix"
        log "Built flake.nix"
    fi
    if [ -f "$SRC_DIR/flake.lock" ]; then
        inject_header "$SRC_DIR/flake.lock" "$DIST_DIR/flake.lock"
        log "Built flake.lock"
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

    # GHA actions (dist/actions/ → .github/actions/)
    if [ -d "$DIST_DIR/actions" ]; then
        mkdir -p "$REPO_ROOT/.github/actions"
        cp -r "$DIST_DIR/actions/"* "$REPO_ROOT/.github/actions/" 2>/dev/null || true
        log "Deployed actions → .github/actions/"
    fi

    # GHA flake (dist/flake.{nix,lock} → .github/)
    for f in flake.nix flake.lock; do
        if [ -f "$DIST_DIR/$f" ]; then
            cp "$DIST_DIR/$f" "$REPO_ROOT/.github/$f"
            log "Deployed $f → .github/"
        fi
    done

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

        # Install read-only pre-commit hook in each submodule's gitdir.
        # Submodules are read-only — commits inside them desync the parent
        # gitlink. This hook hard-blocks any `git commit` from inside a
        # submodule worktree. Source: cloud-submodule-readonly-pre-commit.sh.
        RO_HOOK_SRC="$DIST_DIR/scripts/cloud-submodule-readonly-pre-commit.sh"
        if [ -f "$RO_HOOK_SRC" ]; then
            git -C "$REPO_ROOT" config --file .gitmodules --get-regexp 'submodule\..*\.path' 2>/dev/null | while read -r _key _path; do
                [ -n "$_path" ] || continue
                [ -d "$REPO_ROOT/$_path/.git" ] || [ -f "$REPO_ROOT/$_path/.git" ] || continue
                _sm_hooks=$(git -C "$REPO_ROOT/$_path" rev-parse --git-path hooks 2>/dev/null)
                [ -n "$_sm_hooks" ] || continue
                # rev-parse may return relative path (relative to the submodule
                # worktree). Normalize to absolute.
                case "$_sm_hooks" in
                    /*) _hooks_abs="$_sm_hooks" ;;
                    *)  _hooks_abs="$REPO_ROOT/$_path/$_sm_hooks" ;;
                esac
                mkdir -p "$_hooks_abs"
                cp -f "$RO_HOOK_SRC" "$_hooks_abs/pre-commit"
                chmod +x "$_hooks_abs/pre-commit"
                log "submodule '$_path' → installed read-only pre-commit"
            done
            unset _key _path _sm_hooks _hooks_abs
        fi
    fi

    # Gitconfig → include in .git/config
    # Reconcile: unset any local keys owned by dist/gitconfig so they cannot
    # shadow the declared config (last-wins makes post-include entries win).
    if [ -f "$DIST_DIR/gitconfig" ]; then
        _gc_section=""
        while IFS= read -r line; do
            case "$line" in
                \[*\])
                    _gc_section=$(printf '%s' "$line" | sed 's/^\[\([^]]*\)\]$/\1/' | tr '[:upper:]' '[:lower:]')
                    ;;
                *=*)
                    [ -z "$_gc_section" ] && continue
                    _gc_key=$(printf '%s' "$line" | sed -n 's/^[[:space:]]*\([a-zA-Z][a-zA-Z0-9]*\)[[:space:]]*=.*/\1/p' | tr '[:upper:]' '[:lower:]')
                    [ -n "$_gc_key" ] && git -C "$REPO_ROOT" config --local --unset "${_gc_section}.${_gc_key}" 2>/dev/null || true
                    ;;
            esac
        done < "$DIST_DIR/gitconfig"
        unset _gc_section _gc_key
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
