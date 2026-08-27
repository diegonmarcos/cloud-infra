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

# The config tiers, promoted out of the old single 9_others/ directory.
# Prefix says what kind of thing it is: 0_/1_/2_ are config (the dotfile and
# env tier), a_/b_ are the project's own tree, I_ are submodules.
#
#   0_git/     git config + hooks       -> .gitconfig include, core.hooksPath
#   0_apps/    editor & agent dotfiles  -> .claude/ .vscode/ .obsidian/ .mcp.json
#   1_cicd/    workflows, scripts, ops  -> .github/workflows/
#   2_sops/    sops.yaml                -> .sops.yaml
#   9_others/  shared libs + this file
#
# Each tier owns its own dist/, so an artifact's source and its compiled form
# sit together instead of every tier writing into one shared flat directory.
GIT_SRC="$REPO_ROOT/0_git/src";     GIT_DIST="$REPO_ROOT/0_git/dist"
APPS_SRC="$REPO_ROOT/0_apps/src";   APPS_DIST="$REPO_ROOT/0_apps/dist"
CICD_SRC="$REPO_ROOT/1_cicd/src";   CICD_DIST="$REPO_ROOT/1_cicd/dist"
SOPS_SRC="$REPO_ROOT/2_sops";       SOPS_DIST="$REPO_ROOT/2_sops/dist"
LIB_SRC="$SCRIPT_DIR/src";          LIB_DIST="$SCRIPT_DIR/dist"

# Compatibility shims for the body below, which was written against a single
# src/dist pair. Each $SRC_DIR/<sub> and $DIST_DIR/<sub> reference is rewritten
# to its tier above; these two remain only for paths that are genuinely
# tier-agnostic.
SRC_DIR="$LIB_SRC"
DIST_DIR="$LIB_DIST"
TARGET_DIR="$REPO_ROOT/.github/workflows"
SCRIPTS_TARGET="$TARGET_DIR/scripts"
HOOKS_TARGET="$TARGET_DIR/hooks"

# Shared lib: stamps every dist/ artifact with the GENERATED-FILE banner.
# Template + prefix map live in $LIB_SRC/generated-header.json.
export REPO_ROOT
export ENGINE_NAME="1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh"
# shellcheck source=../libs/inject-header.sh
. "$LIB_SRC/inject-header.sh"

log()      { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }
phase()    { printf "\n[%s] ═══ %s ═══\n" "$(date '+%H:%M:%S')" "$1"; }
step()     { printf "[%s]   • %s\n" "$(date '+%H:%M:%S')" "$1"; }
ok()       { printf "[%s]     ✓ %s\n" "$(date '+%H:%M:%S')" "$1"; }
# Concise relative path renderer for log lines
relp()     { printf '%s' "${1#$REPO_ROOT/}"; }
count_glob() { ls -1 $1 2>/dev/null | wc -l | tr -d ' '; }

do_build() {
    phase "BUILD  src/ → dist/  (purpose: render every artifact with the GENERATED-FILE banner so dist/ is the canonical compiled form)"
    # dist/ has exactly one owner again. Before the 1_cloud-configs split this
    # directory was shared with the config engine (build-*.json landed here too),
    # so the purge had to hand-list the subtrees this engine owns — and a missed
    # entry left stale generated files behind looking healthy. One owner means a
    # plain wipe is both correct and self-maintaining.
    step "purging $(relp "$DIST_DIR")/"
    # Purge every tier's dist, not just one. Each tier owns its own compiled
    # output now, so a single rm -rf "$DIST_DIR" would leave 0_git, 0_apps and
    # 1_cicd holding stale artifacts from the previous build — the exact
    # stale-output problem the purge exists to prevent.
    rm -rf "$GIT_DIST" "$APPS_DIST" "$CICD_DIST" "$LIB_DIST" "$SOPS_DIST"
    mkdir -p "$GIT_DIST/hooks" "$APPS_DIST" "$CICD_DIST/scripts" "$LIB_DIST/test" "$SOPS_DIST"
    ok "$(relp "$DIST_DIR")/ ready"

    # Static workflows (src/gha/cicd/*.yml → dist/)
    step "rendering workflows  $(relp "$CICD_SRC")/cicd/*.yml  →  $(relp "$CICD_DIST")/*.yml"
    _n=0
    # A glob that matches nothing is silent: the loop body never runs, the
    # deploy step copies zero files, and the previously-deployed .github/
    # copies stay in place looking healthy. That is exactly what happened when
    # cicd/ moved under gha/ — workflow edits stopped propagating with no
    # error. Fail loudly instead.
    if ! ls "$CICD_SRC"/cicd/*.yml >/dev/null 2>&1; then
        echo "FATAL: no workflows found at $CICD_SRC/cicd/*.yml" >&2
        exit 1
    fi
    for f in "$CICD_SRC"/cicd/*.yml; do
        [ -f "$f" ] || continue
        inject_header "$f" "$CICD_DIST/$(basename "$f")"
        _n=$((_n+1))
    done
    ok "$_n workflow(s) → $(relp "$DIST_DIR")/"

    # Scripts (src/gha/scripts/ + src/gha/ops/ → dist/scripts/)
    #
    # ops/ renders into the SAME dist/scripts/ as the ship engine. The split is
    # editorial — ship/* is machinery the workflows drive, ops/* is what you run
    # by hand — but both install to .github/workflows/scripts/ and workflows
    # reference them by bare filename, so the install path must not change.
    for _sub in scripts ops; do
        [ -d "$CICD_SRC/$_sub" ] || continue
        step "rendering $_sub      $(relp "$SRC_DIR")/gha/$_sub/  →  $(relp "$DIST_DIR")/scripts/"
        inject_header_tree "$CICD_SRC/$_sub" "$CICD_DIST/scripts"
    done
    ok "$(count_glob "$CICD_DIST/scripts/*") files → $(relp "$DIST_DIR")/scripts/"

    # Hooks (src/git-hooks/ → dist/hooks/)
    if [ -d "$GIT_SRC/hooks" ]; then
        step "rendering hooks      $(relp "$SRC_DIR")/hooks/    →  $(relp "$DIST_DIR")/hooks/"
        inject_header_tree "$GIT_SRC/hooks" "$GIT_DIST/hooks"
        ok "$(count_glob "$GIT_DIST/hooks/*") files → $(relp "$DIST_DIR")/hooks/"
    fi

    # Tests (src/test/ → dist/test/)
    if [ -d "$LIB_SRC/../test" ]; then
        step "rendering tests      $(relp "$SRC_DIR")/test/     →  $(relp "$DIST_DIR")/test/    (preflight testers for ship-* workflows)"
        inject_header_tree "$LIB_SRC/../test" "$LIB_DIST/test"
        ok "$(count_glob "$LIB_DIST/test/*") files → $(relp "$DIST_DIR")/test/"
    fi

    # Gitmodules (src/gitconfigs/gitmodules → dist/.gitmodules)
    if [ -f "$GIT_SRC/gitmodules" ]; then
        step "rendering .gitmodules"
        inject_header "$GIT_SRC/gitmodules" "$GIT_DIST/.gitmodules"
        ok "→ $(relp "$DIST_DIR")/.gitmodules"
    fi

    # Gitignore (src/gitconfigs/gitignore → dist/.gitignore)
    if [ -f "$GIT_SRC/gitignore" ]; then
        step "rendering .gitignore"
        inject_header "$GIT_SRC/gitignore" "$GIT_DIST/.gitignore"
        ok "→ $(relp "$DIST_DIR")/.gitignore"
    fi

    # Gitattributes (src/gitconfigs/gitattributes → dist/.gitattributes)
    if [ -f "$GIT_SRC/gitattributes" ]; then
        step "rendering .gitattributes"
        inject_header "$GIT_SRC/gitattributes" "$GIT_DIST/.gitattributes"
        ok "→ $(relp "$DIST_DIR")/.gitattributes"
    fi

    # Gitconfig (src/gitconfigs/gitconfig → dist/)
    if [ -f "$GIT_SRC/gitconfig" ]; then
        step "rendering gitconfig (will be included by .git/config in deploy phase)"
        inject_header "$GIT_SRC/gitconfig" "$GIT_DIST/gitconfig"
        ok "→ $(relp "$DIST_DIR")/gitconfig"
    fi

    # GHA actions (src/gha/actions/ → dist/actions/)
    if [ -d "$CICD_SRC/actions" ]; then
        step "rendering GHA composite actions  $(relp "$SRC_DIR")/actions/  →  $(relp "$DIST_DIR")/actions/"
        inject_header_tree "$CICD_SRC/actions" "$CICD_DIST/actions"
        ok "$(count_glob "$CICD_DIST/actions/*") action(s) → $(relp "$DIST_DIR")/actions/"
    fi

    # GHA flake (src/flake.nix, src/flake.lock → dist/)
    if [ -f "$CICD_SRC/flake.nix" ]; then
        step "rendering flake.nix"
        inject_header "$CICD_SRC/flake.nix" "$CICD_DIST/flake.nix"
        ok "→ $(relp "$DIST_DIR")/flake.nix"
    fi
    if [ -f "$CICD_SRC/flake.lock" ]; then
        step "rendering flake.lock (verbatim — in skip_basenames for header injection)"
        inject_header "$CICD_SRC/flake.lock" "$CICD_DIST/flake.lock"
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
    for f in "$CICD_DIST"/*.yml; do
        [ -f "$f" ] || continue
        cp "$f" "$TARGET_DIR/"
        _n=$((_n+1))
    done
    ok "$_n workflow(s) → $(relp "$TARGET_DIR")/"

    # Remove workflows whose source is gone. Deploy used to be copy-only, so a
    # workflow deleted from src/ stayed in .github/ forever — and GitHub keeps
    # RUNNING it on its schedule. It also let a hand-written file survive there
    # with no source at all (test-wg-reach.yml did, for months, failing the
    # generated-header check the whole time). Safe to purge now that
    # .github/workflows/ has exactly one owner; before the 1_cloud-configs
    # split a second engine wrote here and this would have deleted its output.
    _orphans=0
    for f in "$TARGET_DIR"/*.yml; do
        [ -f "$f" ] || continue
        [ -f "$CICD_DIST/$(basename "$f")" ] && continue
        step "removing orphan workflow $(basename "$f") — no source in $(relp "$SRC_DIR")/gha/cicd/"
        rm -f "$f"
        _orphans=$((_orphans+1))
    done
    [ "$_orphans" -gt 0 ] && ok "$_orphans orphan workflow(s) removed"

    # Scripts
    if [ -d "$CICD_DIST/scripts" ]; then
        step "deploying scripts  $(relp "$DIST_DIR")/scripts/  →  $(relp "$SCRIPTS_TARGET")/  (consumed by workflow run: blocks)"
        cp -r "$CICD_DIST/scripts/"* "$SCRIPTS_TARGET/" 2>/dev/null || true
        chmod +x "$SCRIPTS_TARGET/"*.sh 2>/dev/null || true
        ok "$(count_glob "$SCRIPTS_TARGET/*") files → $(relp "$SCRIPTS_TARGET")/"
    fi

    # Hooks
    if [ -d "$GIT_DIST/hooks" ]; then
        step "deploying hooks  $(relp "$DIST_DIR")/hooks/  →  $(relp "$HOOKS_TARGET")/  (git hooksPath points here via gitconfig include)"
        cp -r "$GIT_DIST/hooks/"* "$HOOKS_TARGET/" 2>/dev/null || true
        chmod +x "$HOOKS_TARGET/"*.sh 2>/dev/null || true
        ok "$(count_glob "$HOOKS_TARGET/*") files → $(relp "$HOOKS_TARGET")/"
    fi

    # GHA actions (dist/actions/ → .github/actions/)
    if [ -d "$CICD_DIST/actions" ]; then
        step "deploying GHA composite actions  $(relp "$DIST_DIR")/actions/  →  .github/actions/"
        mkdir -p "$REPO_ROOT/.github/actions"
        cp -r "$CICD_DIST/actions/"* "$REPO_ROOT/.github/actions/" 2>/dev/null || true
        ok "$(count_glob "$REPO_ROOT/.github/actions/*") action(s) → .github/actions/"
    fi

    # GHA flake (dist/flake.{nix,lock} → .github/)
    for f in flake.nix flake.lock; do
        if [ -f "$CICD_DIST/$f" ]; then
            step "deploying $f  $(relp "$DIST_DIR")/$f  →  .github/$f  (used by GHA setup-nix actions)"
            cp "$CICD_DIST/$f" "$REPO_ROOT/.github/$f"
            ok "→ .github/$f"
        fi
    done

    # LICENSE — copied VERBATIM, never header-injected.
    #
    # Every other artifact here gets the GENERATED-FILE banner stamped into it.
    # A licence must not: GitHub's licence detector and SPDX scanners match the
    # text, and a banner above it can make a recognised licence unrecognised.
    # Altering the text of a licence is also not a cosmetic act. So it is a
    # plain copy, source of truth in 0_git/src/ like the other git files.
    if [ -f "$GIT_SRC/LICENSE" ]; then
        step "copying LICENSE (verbatim — no generated-file banner)"
        cp "$GIT_SRC/LICENSE" "$GIT_DIST/LICENSE"
        cp "$GIT_SRC/LICENSE" "$REPO_ROOT/LICENSE"
        ok "→ LICENSE"
    fi

    # Repo-root configs (.gitmodules etc)
    for f in "$GIT_DIST"/.git*; do
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
        # `submodule update` force-checks-out EVERY submodule to the gitlink the
        # parent recorded. On a read-only submodule that is the whole point. On an
        # authored one (`writable = true`) it is silent data loss: a commit made
        # inside the submodule is yanked back to whatever SHA the parent last
        # recorded, leaving a detached HEAD on a stale commit. Hit for real on
        # a_solutions 2026-08-27 — build.sh reset it from 9f431b0a to 3bd6b3fd in
        # the same breath as printing "writable, read-only hook removed", because
        # `writable` governed the hook but not the checkout.
        #
        # So writable submodules are INITIALISED but never re-checked-out: an
        # empty worktree still gets cloned, so a cold clone.sh works exactly as
        # before, and an existing one keeps whatever HEAD its author left it on.
        # Keep in sync with 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh —
        # this bootstrap must stand alone, so the logic is duplicated.
        git -C "$REPO_ROOT" config --file .gitmodules --get-regexp 'submodule\..*\.path' 2>/dev/null | while read -r _key _path; do
            [ -n "$_path" ] || continue
            _sm_name="${_key#submodule.}"; _sm_name="${_sm_name%.path}"
            if [ "$(git -C "$REPO_ROOT" config --file .gitmodules --get "submodule.${_sm_name}.writable" 2>/dev/null)" = "true" ] \
               && { [ -d "$REPO_ROOT/$_path/.git" ] || [ -f "$REPO_ROOT/$_path/.git" ]; }; then
                ok "submodule '$_sm_name' → writable and already checked out; leaving its HEAD where its author left it"
                continue
            fi
            git -C "$REPO_ROOT" submodule update --init -- "$_path" 2>&1 | while IFS= read -r line; do
                log "  submodule: $line"
            done
        done
        ok "submodules synced"

        # Install read-only pre-commit hook in each submodule's gitdir.
        # Submodules are read-only — commits inside them desync the parent
        # gitlink. This hook hard-blocks any `git commit` from inside a
        # submodule worktree. Source: cloud-submodule-readonly-pre-commit.sh.
        step "installing read-only pre-commit hooks in each submodule (blocks commits-from-inside that would desync the parent gitlink)"
        RO_HOOK_SRC="$CICD_DIST/scripts/cloud-submodule-readonly-pre-commit.sh"
        if [ -f "$RO_HOOK_SRC" ]; then
            git -C "$REPO_ROOT" config --file .gitmodules --get-regexp 'submodule\..*\.path' 2>/dev/null | while read -r _key _path; do
                [ -n "$_path" ] || continue
                [ -d "$REPO_ROOT/$_path/.git" ] || [ -f "$REPO_ROOT/$_path/.git" ] || continue
                # A submodule may opt out of the read-only contract by declaring
                # `writable = true`. Index submodules (cloud) are consumed here and
                # never authored, so they stay read-only; authored trees such as
                # a_solutions are edited in place and pushed from their own repo.
                # Keep in sync with 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh —
                # this bootstrap must stand alone, so the logic is duplicated.
                _sm_name="${_key#submodule.}"; _sm_name="${_sm_name%.path}"
                if [ "$(git -C "$REPO_ROOT" config --file .gitmodules --get "submodule.${_sm_name}.writable" 2>/dev/null)" = "true" ]; then
                    # Converge to the declaration: remove a hook left over from an
                    # earlier run, don't merely skip installing one.
                    _w_hooks=$(git -C "$REPO_ROOT/$_path" rev-parse --git-path hooks 2>/dev/null)
                    case "$_w_hooks" in
                        /*) ;;
                        *)  _w_hooks="$REPO_ROOT/$_path/$_w_hooks" ;;
                    esac
                    rm -f "$_w_hooks/pre-commit"
                    ok "submodule '$_path' → writable, read-only hook removed"
                    continue
                fi
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
    if [ -f "$GIT_DIST/gitconfig" ]; then
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
        done < "$GIT_DIST/gitconfig"
        unset _gc_section _gc_key
        git -C "$REPO_ROOT" config --local include.path ../0_git/dist/gitconfig 2>/dev/null || true
        ok "gitconfig include wired into .git/config"
    fi

    log "DEPLOY complete — every artifact is at its install path"
}

# ── dotfiles ────────────────────────────────────────────────────────────────
# src/apps/<tool>/ → dist/dotfiles/<tool>/ → <repo>/<target>/
#
# Deliberately NOT purge-then-copy: .claude/ and .obsidian/ mix managed config
# with per-machine state (pane layout, local permission overrides), so the
# target dir is never wiped. See src/apps/manifest.json:never_manage.
do_dotfiles() {
    phase "DOTFILES  src/apps/ → dist/dotfiles/ → repo root"
    sh "$LIB_SRC/deploy-dotfiles.sh" "$APPS_SRC" "$APPS_DIST/dotfiles" "$REPO_ROOT"
}

CMD="${1:-ship}"
case "$CMD" in
    # build       = src/  → dist/                  (compile only)
    # deploy/ship = src/  → dist/  → install path  (full pipeline; default)
    # `ship` matches the rest of the cloud repo's per-service `build.sh ship`
    # convention; `deploy`/`all` kept as synonyms for muscle memory.
    dotfiles)
        log "MODE: dotfiles  (src/apps/ → dist/dotfiles/ → repo root)"
        do_dotfiles
        ;;
    build)
        log "MODE: build  (src/ → dist/ — compile only, no deploy)"
        do_build
        log "FINISHED — dist/ ready. Run \`$0 deploy\` (or \`ship\`) to push it to install paths."
        ;;
    deploy|ship|all|"")
        log "MODE: ${CMD:-ship}  (src/ → dist/ → install paths — full pipeline)"
        do_build
        do_deploy
        do_dotfiles
        log "FINISHED — every artifact compiled AND installed at its target path."
        ;;
    *)
        cat >&2 <<USAGE
Usage: $0 [build | ship | deploy]

  build           src/                       → dist/                              (compile only — no deploy)
  ship  (default) src/  → dist/  → installed (full pipeline; default)
  deploy          src/  → dist/  → installed (alias for ship)
  dotfiles        src/apps/ → dist/dotfiles/ → .claude/ .vscode/ .obsidian/

After 'ship'/'deploy', .github/workflows/, .github/actions/, .github/flake.{nix,lock},
.gitmodules, .gitignore, gitconfig include, scripts/, hooks/, and submodule
read-only pre-commits are all in place.
USAGE
        exit 1
        ;;
esac
