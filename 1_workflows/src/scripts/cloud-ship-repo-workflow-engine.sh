#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Workflow engine: build (src→dist) + deploy (dist→.github/)       ║
# ║                                                                  ║
# ║ Usage: ./build.sh              # build + deploy (default)        ║
# ║        ./build.sh build        # src → dist only                 ║
# ║        ./build.sh deploy       # dist → .github/ + repo root    ║
# ╚══════════════════════════════════════════════════════════════════╝
set -e
chmod +x "$0"

# Prefer termux coreutils over nix cp, which fails with libpthread on Android.
export PATH="/data/data/com.termux.nix/files/usr/bin:$PATH"

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

log()      { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }
phase()    { printf "\n[%s] ═══ %s ═══\n" "$(date '+%H:%M:%S')" "$1"; }
step()     { printf "[%s]   • %s\n" "$(date '+%H:%M:%S')" "$1"; }
ok()       { printf "[%s]     ✓ %s\n" "$(date '+%H:%M:%S')" "$1"; }
# Concise relative path renderer for log lines
relp()     { printf '%s' "${1#$REPO_ROOT/}"; }
count_glob() { ls -1 $1 2>/dev/null | wc -l | tr -d ' '; }

do_build() {
    phase "BUILD  src/ → dist/  (purpose: render every artifact with the GENERATED-FILE banner so dist/ is the canonical compiled form)"
    step "purging $(relp "$DIST_DIR")/ — ensures src/ deletions propagate (no orphaned scripts/hooks/symlinks)"
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR" "$DIST_DIR/scripts" "$DIST_DIR/hooks" "$DIST_DIR/test"
    ok "$(relp "$DIST_DIR")/ ready"

    # Static workflows (src/cicd/*.yml → dist/)
    step "rendering workflows  $(relp "$SRC_DIR")/cicd/*.yml  →  $(relp "$DIST_DIR")/*.yml"
    _n=0
    for f in "$SRC_DIR"/cicd/*.yml; do
        [ -f "$f" ] || continue
        inject_header "$f" "$DIST_DIR/$(basename "$f")"
        _n=$((_n+1))
    done
    ok "$_n workflow(s) → $(relp "$DIST_DIR")/"

    # Scripts (src/scripts/ → dist/scripts/)
    if [ -d "$SRC_DIR/scripts" ]; then
        step "rendering scripts    $(relp "$SRC_DIR")/scripts/  →  $(relp "$DIST_DIR")/scripts/"
        inject_header_tree "$SRC_DIR/scripts" "$DIST_DIR/scripts"
        ok "$(count_glob "$DIST_DIR/scripts/*") files → $(relp "$DIST_DIR")/scripts/"
    fi

    # Hooks (src/hooks/ → dist/hooks/)
    if [ -d "$SRC_DIR/hooks" ]; then
        step "rendering hooks      $(relp "$SRC_DIR")/hooks/    →  $(relp "$DIST_DIR")/hooks/"
        inject_header_tree "$SRC_DIR/hooks" "$DIST_DIR/hooks"
        ok "$(count_glob "$DIST_DIR/hooks/*") files → $(relp "$DIST_DIR")/hooks/"
    fi

    # Tests (src/test/ → dist/test/)
    if [ -d "$SRC_DIR/test" ]; then
        step "rendering tests      $(relp "$SRC_DIR")/test/     →  $(relp "$DIST_DIR")/test/    (preflight testers for ship-* workflows)"
        inject_header_tree "$SRC_DIR/test" "$DIST_DIR/test"
        ok "$(count_glob "$DIST_DIR/test/*") files → $(relp "$DIST_DIR")/test/"
    fi

    # Gitmodules (src/modules/gitmodules → dist/.gitmodules)
    if [ -f "$SRC_DIR/modules/gitmodules" ]; then
        step "rendering .gitmodules"
        inject_header "$SRC_DIR/modules/gitmodules" "$DIST_DIR/.gitmodules"
        ok "→ $(relp "$DIST_DIR")/.gitmodules"
    fi

    # Gitignore (src/gitignore → dist/.gitignore)
    if [ -f "$SRC_DIR/gitignore" ]; then
        step "rendering .gitignore"
        inject_header "$SRC_DIR/gitignore" "$DIST_DIR/.gitignore"
        ok "→ $(relp "$DIST_DIR")/.gitignore"
    fi

    # Gitconfig (src/gitconfig → dist/)
    if [ -f "$SRC_DIR/gitconfig" ]; then
        step "rendering gitconfig (will be included by .git/config in deploy phase)"
        inject_header "$SRC_DIR/gitconfig" "$DIST_DIR/gitconfig"
        ok "→ $(relp "$DIST_DIR")/gitconfig"
    fi

    # GHA actions (src/actions/ → dist/actions/)
    if [ -d "$SRC_DIR/actions" ]; then
        step "rendering GHA composite actions  $(relp "$SRC_DIR")/actions/  →  $(relp "$DIST_DIR")/actions/"
        inject_header_tree "$SRC_DIR/actions" "$DIST_DIR/actions"
        ok "$(count_glob "$DIST_DIR/actions/*") action(s) → $(relp "$DIST_DIR")/actions/"
    fi

    # GHA flake (src/flake.nix, src/flake.lock → dist/)
    if [ -f "$SRC_DIR/flake.nix" ]; then
        step "rendering flake.nix"
        inject_header "$SRC_DIR/flake.nix" "$DIST_DIR/flake.nix"
        ok "→ $(relp "$DIST_DIR")/flake.nix"
    fi
    if [ -f "$SRC_DIR/flake.lock" ]; then
        step "rendering flake.lock (verbatim — in skip_basenames for header injection)"
        inject_header "$SRC_DIR/flake.lock" "$DIST_DIR/flake.lock"
        ok "→ $(relp "$DIST_DIR")/flake.lock"
    fi
    log "BUILD complete — dist/ is the canonical compiled form"
}

do_deploy() {
    phase "DEPLOY  dist/ → install paths  (purpose: copy compiled artifacts to where GHA / git / submodules actually read them)"
    mkdir -p "$TARGET_DIR" "$SCRIPTS_TARGET" "$HOOKS_TARGET"

    # Workflows
    step "deploying workflows  $(relp "$DIST_DIR")/*.yml  →  $(relp "$TARGET_DIR")/  (where GitHub Actions reads them)"
    _n=0
    for f in "$DIST_DIR"/*.yml; do
        [ -f "$f" ] || continue
        cp "$f" "$TARGET_DIR/"
        _n=$((_n+1))
    done
    ok "$_n workflow(s) → $(relp "$TARGET_DIR")/"

    # Scripts
    if [ -d "$DIST_DIR/scripts" ]; then
        step "deploying scripts  $(relp "$DIST_DIR")/scripts/  →  $(relp "$SCRIPTS_TARGET")/  (consumed by workflow run: blocks)"
        cp -r "$DIST_DIR/scripts/"* "$SCRIPTS_TARGET/" 2>/dev/null || true
        chmod +x "$SCRIPTS_TARGET/"*.sh 2>/dev/null || true
        ok "$(count_glob "$SCRIPTS_TARGET/*") files → $(relp "$SCRIPTS_TARGET")/"
    fi

    # Hooks
    if [ -d "$DIST_DIR/hooks" ]; then
        step "deploying hooks  $(relp "$DIST_DIR")/hooks/  →  $(relp "$HOOKS_TARGET")/  (git hooksPath points here via gitconfig include)"
        cp -r "$DIST_DIR/hooks/"* "$HOOKS_TARGET/" 2>/dev/null || true
        chmod +x "$HOOKS_TARGET/"*.sh 2>/dev/null || true
        ok "$(count_glob "$HOOKS_TARGET/*") files → $(relp "$HOOKS_TARGET")/"
    fi

    # GHA actions (dist/actions/ → .github/actions/)
    if [ -d "$DIST_DIR/actions" ]; then
        step "deploying GHA composite actions  $(relp "$DIST_DIR")/actions/  →  .github/actions/"
        mkdir -p "$REPO_ROOT/.github/actions"
        cp -r "$DIST_DIR/actions/"* "$REPO_ROOT/.github/actions/" 2>/dev/null || true
        ok "$(count_glob "$REPO_ROOT/.github/actions/*") action(s) → .github/actions/"
    fi

    # GHA flake (dist/flake.{nix,lock} → .github/)
    for f in flake.nix flake.lock; do
        if [ -f "$DIST_DIR/$f" ]; then
            step "deploying $f  $(relp "$DIST_DIR")/$f  →  .github/$f  (used by GHA setup-nix actions)"
            cp "$DIST_DIR/$f" "$REPO_ROOT/.github/$f"
            ok "→ .github/$f"
        fi
    done

    # Repo-root configs (.gitmodules etc)
    for f in "$DIST_DIR"/.git*; do
        [ -f "$f" ] || continue
        step "deploying $(basename "$f")  $(relp "$f")  →  repo root  (canonical for git to consume)"
        cp "$f" "$REPO_ROOT/"
        ok "→ $(basename "$f")"
    done

    # Sync submodules: ensure all entries in .gitmodules are registered + cloned
    if [ -f "$REPO_ROOT/.gitmodules" ]; then
        step "reconciling submodules from .gitmodules (register + clone any new ones, sync URLs, update all)"
        # Read declared submodules from .gitmodules
        git -C "$REPO_ROOT" config --file .gitmodules --get-regexp 'submodule\..*\.path' 2>/dev/null | while read -r key path; do
            name=$(echo "$key" | sed 's/^submodule\.\(.*\)\.path$/\1/')
            url=$(git -C "$REPO_ROOT" config --file .gitmodules "submodule.$name.url" 2>/dev/null || true)
            if git -C "$REPO_ROOT" ls-files --stage "$path" 2>/dev/null | grep -q '^160000'; then
                ok "submodule '$name' already registered at $path"
            else
                log "submodule '$name' not in index — adding from .gitmodules ($url → $path)"
                git -C "$REPO_ROOT" submodule add --force --name "$name" "$url" "$path" 2>&1 | while IFS= read -r line; do
                    log "  $line"
                done
            fi
        done
        git -C "$REPO_ROOT" submodule sync 2>/dev/null || true
        git -C "$REPO_ROOT" submodule update --init 2>&1 | while IFS= read -r line; do
            log "  submodule: $line"
        done
        ok "submodules synced"

        # Install read-only pre-commit hook in each submodule's gitdir.
        # Submodules are read-only — commits inside them desync the parent
        # gitlink. This hook hard-blocks any `git commit` from inside a
        # submodule worktree. Source: cloud-submodule-readonly-pre-commit.sh.
        step "installing read-only pre-commit hooks in each submodule (blocks commits-from-inside that would desync the parent gitlink)"
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
                ok "submodule '$_path' → read-only pre-commit installed"
            done
            unset _key _path _sm_hooks _hooks_abs
        fi
    fi

    # Gitconfig → include in .git/config
    # Reconcile: unset any local keys owned by dist/gitconfig so they cannot
    # shadow the declared config (last-wins makes post-include entries win).
    if [ -f "$DIST_DIR/gitconfig" ]; then
        step "reconciling local .git/config to include $(relp "$DIST_DIR")/gitconfig (unsets shadowing local keys, then add include.path)"
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
        ok "gitconfig include wired into .git/config"
    fi

    log "DEPLOY complete — every artifact is at its install path"
}

CMD="${1:-ship}"
case "$CMD" in
    # build       = src/  → dist/                  (compile only)
    # deploy/ship = src/  → dist/  → install path  (full pipeline; default)
    # `ship` matches the rest of the cloud repo's per-service `build.sh ship`
    # convention; `deploy`/`all` kept as synonyms for muscle memory.
    build)
        log "MODE: build  (src/ → dist/ — compile only, no deploy)"
        do_build
        log "FINISHED — dist/ ready. Run \`$0 deploy\` (or \`ship\`) to push it to install paths."
        ;;
    deploy|ship|all|"")
        log "MODE: ${CMD:-ship}  (src/ → dist/ → install paths — full pipeline)"
        do_build
        do_deploy
        log "FINISHED — every artifact compiled AND installed at its target path."
        ;;
    *)
        cat >&2 <<USAGE
Usage: $0 [build | ship | deploy]

  build           src/                       → dist/                              (compile only — no deploy)
  ship  (default) src/  → dist/  → installed (full pipeline; default)
  deploy          src/  → dist/  → installed (alias for ship)

After 'ship'/'deploy', .github/workflows/, .github/actions/, .github/flake.{nix,lock},
.gitmodules, .gitignore, gitconfig include, scripts/, hooks/, and submodule
read-only pre-commits are all in place.
USAGE
        exit 1
        ;;
esac
