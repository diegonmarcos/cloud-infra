#!/bin/sh
# git.sh — Git wrapper for cloud/ repo
# Reads git.yaml for merge strategies and regen rules.
# Passes all unknown commands to real git.
# Usage: sh git.sh <command> [args...]
set -e

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
GIT_YAML="$REPO_ROOT/git.yaml"

# ── Parse git.yaml (POSIX, no yq dependency) ────────────────────

# Extract list values under a key (one per line)
# Usage: yaml_list "remote_wins" → prints each file
yaml_list() {
    _key="$1" _in_key=0
    while IFS= read -r _line; do
        case "$_line" in
            "$_key:"*) _in_key=1; continue ;;
        esac
        if [ "$_in_key" = "1" ]; then
            case "$_line" in
                "  - "*)  printf "%s\n" "${_line#  - }" ;;
                "  "*|"") continue ;;  # nested keys or blank
                *)        break ;;     # next top-level key
            esac
        fi
    done < "$GIT_YAML"
}

# Extract scalar value: yaml_scalar "regenerate" "engine"
yaml_scalar() {
    _section="$1" _key="$2" _in_section=0
    while IFS= read -r _line; do
        case "$_line" in
            "$_section:"*) _in_section=1; continue ;;
        esac
        if [ "$_in_section" = "1" ]; then
            case "$_line" in
                "  $_key: "*)  printf "%s" "${_line#*: }"; return ;;
                "  "*|"")      continue ;;
                *)             break ;;
            esac
        fi
    done < "$GIT_YAML"
}

REMOTE_WINS_FILES="$(yaml_list "remote_wins")"
ENGINE_DIR="$REPO_ROOT/$(yaml_scalar "regenerate" "engine")"
ENGINE_TRIGGER="$(yaml_scalar "regenerate" "trigger")"
REGEN_OUTPUTS="$(yaml_list "outputs" < "$GIT_YAML" 2>/dev/null)"
# outputs is nested under regenerate — parse manually
REGEN_OUTPUTS=""
_in_outputs=0
while IFS= read -r _line; do
    case "$_line" in
        "  outputs:"*) _in_outputs=1; continue ;;
    esac
    if [ "$_in_outputs" = "1" ]; then
        case "$_line" in
            "    - "*)  REGEN_OUTPUTS="$REGEN_OUTPUTS ${_line#    - }" ;;
            *)          [ -n "$REGEN_OUTPUTS" ] && break ;;
        esac
    fi
done < "$GIT_YAML"

# ── Custom commands ──────────────────────────────────────────────

cmd_config() {
    TSX="$ENGINE_DIR/node_modules/.bin/tsx"
    TOPO="$ENGINE_DIR/engines/gen-topology.ts"
    CONF="$ENGINE_DIR/engines/gen-configs.ts"

    if [ ! -x "$TSX" ]; then
        printf "[git.sh] SKIP: tsx not found (run: cd %s && npm install)\n" "$ENGINE_DIR"
        return 1
    fi
    if [ ! -f "$TOPO" ] || [ ! -f "$CONF" ]; then
        printf "[git.sh] SKIP: engine sources not available locally\n"
        return 1
    fi

    printf "[git.sh] Regenerating configs...\n"
    "$TSX" "$TOPO"
    "$TSX" "$CONF"
    printf "[git.sh] Done.\n"
}

# Resolve conflicts on remote_wins files during rebase
resolve_remote_wins() {
    _conflicted="$(git -C "$REPO_ROOT" diff --name-only --diff-filter=U 2>/dev/null)" || return 0
    [ -z "$_conflicted" ] && return 0

    _resolved=0
    for _file in $REMOTE_WINS_FILES; do
        if printf "%s\n" "$_conflicted" | grep -qxF "$_file"; then
            printf "[git.sh] Conflict in %s — accepting remote version\n" "$_file"
            git -C "$REPO_ROOT" checkout --theirs -- "$_file"
            git -C "$REPO_ROOT" add "$_file"
            _resolved=1
        fi
    done

    # Check if there are still unresolved conflicts
    _remaining="$(git -C "$REPO_ROOT" diff --name-only --diff-filter=U 2>/dev/null)" || true
    if [ -n "$_remaining" ]; then
        printf "[git.sh] ERROR: Unresolved conflicts remain:\n"
        printf "  %s\n" $_remaining
        printf "[git.sh] Fix manually, then: git rebase --continue\n"
        exit 1
    fi

    if [ "$_resolved" = "1" ]; then
        GIT_EDITOR=true git -C "$REPO_ROOT" rebase --continue
    fi
}

cmd_push() {
    # 1. Pull --rebase (sync with remote, no merge commit)
    printf "[git.sh] Pulling with rebase...\n"
    if ! git -C "$REPO_ROOT" pull --rebase origin main 2>&1; then
        # Rebase failed — try to auto-resolve remote_wins files
        resolve_remote_wins
    fi

    # 2. Regenerate configs (fast + idempotent — no diff = no amend)
    if cmd_config; then
        # Stage regenerated outputs
        for _f in $REGEN_OUTPUTS; do
            git -C "$REPO_ROOT" add "$REPO_ROOT/$_f" 2>/dev/null || true
        done

        # Amend into last commit if outputs changed (no new commit)
        if ! git -C "$REPO_ROOT" diff --cached --quiet 2>/dev/null; then
            printf "[git.sh] Folding regenerated configs into last commit...\n"
            git -C "$REPO_ROOT" commit --amend --no-edit
        fi
    else
        printf "[git.sh] Skipping regen — GHA will handle it\n"
    fi

    # 4. Push
    printf "[git.sh] Pushing...\n"
    git -C "$REPO_ROOT" push "$@"
}

# ── Dispatch ─────────────────────────────────────────────────────

case "${1:-}" in
    config)
        shift
        cmd_config "$@"
        ;;
    push)
        shift
        cmd_push "$@"
        ;;
    *)
        # Pass through to real git
        git -C "$REPO_ROOT" "$@"
        ;;
esac
