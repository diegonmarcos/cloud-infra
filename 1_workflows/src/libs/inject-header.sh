#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Shared library: inject the GENERATED-FILE banner into an artifact║
# ║                                                                  ║
# ║ Usage (from an engine script):                                   ║
# ║   source "$SRC_DIR/libs/inject-header.sh"                        ║
# ║   inject_header "<src>" "<dest>"            # single file        ║
# ║   inject_header_tree "<src_dir>" "<dest_dir>" # whole tree       ║
# ║                                                                  ║
# ║ Data-driven: reads template + prefix map from                    ║
# ║   1_workflows/src/libs/generated-header.json                     ║
# ║                                                                  ║
# ║ Behaviour:                                                       ║
# ║   · Shebang-aware — header goes AFTER `#!...` line               ║
# ║   · JSON objects — inject `_generated` meta-key via jq           ║
# ║   · Binary / unknown / skip_extensions — plain cp, no stamp      ║
# ║                                                                  ║
# ║ Env inputs:                                                      ║
# ║   ENGINE_NAME  (rel path to calling engine script)               ║
# ║   REPO_ROOT    (abs path to repo root)                           ║
# ╚══════════════════════════════════════════════════════════════════╝

# Guard against double-sourcing.
[ "${_INJECT_HEADER_LIB_LOADED:-}" = "1" ] && return 0
_INJECT_HEADER_LIB_LOADED=1

_ih_tpl_file() {
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    echo "$lib_dir/generated-header.json"
}

_ih_repo_root() {
    if [ -n "${REPO_ROOT:-}" ]; then
        echo "$REPO_ROOT"
        return
    fi
    cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd
}

_ih_engine() {
    echo "${ENGINE_NAME:-1_workflows/src/scripts/cloud-ship-repo-workflow-engine.sh}"
}

# Emit the comment prefix for a file, or empty string if unknown.
_ih_prefix_for() {
    local path="$1"
    local tpl
    tpl="$(_ih_tpl_file)"
    local base="${path##*/}"
    local ext="${base##*.}"

    # basename match wins (hooks with no extension, gitignore/gitmodules/gitconfig)
    local by_base
    by_base=$(jq -r --arg n "$base" '.comment_by_basename[$n] // empty' "$tpl" 2>/dev/null)
    [ -n "$by_base" ] && { echo "$by_base"; return; }

    # extension match (if ext != base, i.e. file actually has an extension)
    if [ "$ext" != "$base" ]; then
        local by_ext
        by_ext=$(jq -r --arg e "$ext" '.comment_by_ext[$e] // empty' "$tpl" 2>/dev/null)
        [ -n "$by_ext" ] && { echo "$by_ext"; return; }
    fi

    echo ""
}

# Is this file a skip_extension (binary, vendored, etc.) or skip_basename
# (auto-managed metadata: lockfiles, terraform state, etc.)?
_ih_should_skip() {
    local path="$1"
    local tpl
    tpl="$(_ih_tpl_file)"
    local base="${path##*/}"
    # Exact basename match (lockfiles, terraform state)
    if jq -er --arg b "$base" '(.skip_basenames // [])[] | select(. == $b)' "$tpl" >/dev/null 2>&1; then
        return 0
    fi
    # Extension suffix match (binaries, vendored minified)
    jq -er --arg b "$base" '.skip_extensions[] | select(. as $e | $b | endswith("." + $e))' "$tpl" >/dev/null 2>&1
}

# Does this look like JSON?
_ih_is_json() {
    local path="$1"
    case "${path##*.}" in
        json) return 0 ;;
        *)    return 1 ;;
    esac
}

# Render the banner lines (no comment prefix yet) with placeholders filled.
_ih_render_banner() {
    local rel_src="$1"
    local engine="$2"
    local tpl
    tpl="$(_ih_tpl_file)"
    local rebuild
    rebuild=$(jq -r '.rebuild_cmd' "$tpl")

    jq -r '.template[]' "$tpl" \
        | sed "s|{{SOURCE}}|$rel_src|g" \
        | sed "s|{{ENGINE}}|$engine|g" \
        | sed "s|{{REBUILD_CMD}}|$rebuild|g"
}

# Build the full header block (prefixed) for a given comment char.
_ih_build_header() {
    local prefix="$1"
    local rel_src="$2"
    local engine="$3"

    _ih_render_banner "$rel_src" "$engine" | while IFS= read -r line; do
        printf '%s %s\n' "$prefix" "$line"
    done
}

# JSON injection: prepend `_generated` meta-key to root object.
# Fails loudly if root is not an object — that schema is not supported.
_ih_inject_json() {
    local src="$1"
    local dest="$2"
    local rel_src="$3"
    local engine="$4"
    local tpl
    tpl="$(_ih_tpl_file)"
    local rebuild
    rebuild=$(jq -r '.rebuild_cmd' "$tpl")

    if ! jq -e 'type == "object"' "$src" >/dev/null 2>&1; then
        echo "ERROR: inject_header: JSON root must be an object (got array/scalar): $src" >&2
        return 1
    fi

    mkdir -p "$(dirname "$dest")"
    jq \
        --arg src "$rel_src" \
        --arg engine "$engine" \
        --arg rebuild "$rebuild" \
        '. = ({
            _generated: {
                warning: "DO NOT EDIT — generated file",
                source:  $src,
                engine:  $engine,
                rebuild: $rebuild
            }
        } + .)' \
        "$src" > "$dest"
}

# Public: inject header when copying `src` → `dest`.
inject_header() {
    local src="$1"
    local dest="$2"
    local repo_root engine rel_src prefix first_line
    repo_root="$(_ih_repo_root)"
    engine="$(_ih_engine)"
    rel_src="${src#$repo_root/}"

    mkdir -p "$(dirname "$dest")"

    # 1. Binary / skip → plain copy.
    if _ih_should_skip "$src"; then
        cp "$src" "$dest"
        return 0
    fi

    # 2. JSON → plain copy by default (many parsers reject unknown keys at
    #    root — npm lockfiles, wrangler.toml sidecars, schema-validated
    #    configs). Meta-key injection available via INJECT_JSON=1 env var.
    if _ih_is_json "$src"; then
        if [ "${INJECT_JSON:-0}" = "1" ]; then
            _ih_inject_json "$src" "$dest" "$rel_src" "$engine"
            return $?
        else
            cp "$src" "$dest"
            return 0
        fi
    fi

    # 3. Text with known comment prefix → banner injection.
    prefix="$(_ih_prefix_for "$src")"
    if [ -z "$prefix" ]; then
        # Unknown file type — plain cp (don't corrupt unfamiliar formats).
        cp "$src" "$dest"
        return 0
    fi

    first_line="$(head -n1 "$src" 2>/dev/null || true)"

    local header
    header="$(_ih_build_header "$prefix" "$rel_src" "$engine")"

    if [ "${first_line:0:2}" = "#!" ]; then
        # Preserve shebang on line 1.
        {
            printf '%s\n\n' "$first_line"
            printf '%s\n\n' "$header"
            tail -n +2 "$src"
        } > "$dest"
    else
        {
            printf '%s\n\n' "$header"
            cat "$src"
        } > "$dest"
    fi

    # Preserve executable bit.
    if [ -x "$src" ]; then chmod +x "$dest"; fi
}

# Public: stamp an already-existing file in place.
#
# Use case: engine steps that emit artifacts via `cat > $DIST_DIR/foo <<EOF`
# (e.g. cloud-ship-container-step-build-docker.sh emits Dockerfile.native).
# There is no src/ counterpart to inject from — the file is generated content.
# This helper rewrites the file with the GENERATED-FILE banner prepended,
# using the same prefix/shebang/skip rules as inject_header().
#
# Args:
#   $1 = path to the file to stamp (will be rewritten in place)
#   $2 = optional virtual source label for the {{SOURCE}} placeholder
#        (defaults to the file path, relative to repo root)
stamp_header_inplace() {
    local target="$1"
    local virtual_src="${2:-$target}"
    local repo_root engine rel_src prefix first_line tmp header
    [ -f "$target" ] || return 0
    repo_root="$(_ih_repo_root)"
    engine="$(_ih_engine)"
    rel_src="${virtual_src#$repo_root/}"

    # Skip rules apply to in-place stamping too.
    if _ih_should_skip "$target"; then
        return 0
    fi

    # JSON: only stamp when explicitly opted in (matches inject_header).
    if _ih_is_json "$target"; then
        if [ "${INJECT_JSON:-0}" = "1" ]; then
            tmp="$(mktemp)"
            _ih_inject_json "$target" "$tmp" "$rel_src" "$engine" || { rm -f "$tmp"; return 1; }
            mv "$tmp" "$target"
        fi
        return 0
    fi

    prefix="$(_ih_prefix_for "$target")"
    [ -z "$prefix" ] && return 0   # unknown type — leave untouched

    # Idempotent: skip if already stamped.
    local marker
    marker=$(jq -r '.marker' "$(_ih_tpl_file)")
    if head -n 20 "$target" | grep -qF "$marker"; then
        return 0
    fi

    first_line="$(head -n1 "$target" 2>/dev/null || true)"
    header="$(_ih_build_header "$prefix" "$rel_src" "$engine")"
    tmp="$(mktemp)"
    if [ "${first_line:0:2}" = "#!" ]; then
        {
            printf '%s\n\n' "$first_line"
            printf '%s\n\n' "$header"
            tail -n +2 "$target"
        } > "$tmp"
    else
        {
            printf '%s\n\n' "$header"
            cat "$target"
        } > "$tmp"
    fi
    if [ -x "$target" ]; then chmod +x "$tmp"; fi
    mv "$tmp" "$target"
}

# Public: recursively walk src_dir and inject header into every file,
# mirroring the tree under dest_dir.
inject_header_tree() {
    local src_dir="$1"
    local dest_dir="$2"
    [ -d "$src_dir" ] || return 0
    local f rel dest
    # `find -L` dereferences symlinks, matching `cp -rL` semantics the
    # engines used previously (symlinks-to-files are copied as real files).
    while IFS= read -r -d '' f; do
        rel="${f#$src_dir/}"
        dest="$dest_dir/$rel"
        inject_header "$f" "$dest"
    done < <(find -L "$src_dir" -type f -print0)
}

# ── CLI entry point ────────────────────────────────────────────────────
# Allows POSIX-sh engines to call the lib as a subprocess:
#   /path/to/inject-header.sh file <src> <dest>
#   /path/to/inject-header.sh tree <src_dir> <dest_dir>
# Sourced usage still works — this block only runs when executed directly.
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
    case "${1:-}" in
        file)
            [ $# -eq 3 ] || { echo "usage: $0 file <src> <dest>" >&2; exit 2; }
            inject_header "$2" "$3"
            ;;
        tree)
            [ $# -eq 3 ] || { echo "usage: $0 tree <src_dir> <dest_dir>" >&2; exit 2; }
            inject_header_tree "$2" "$3"
            ;;
        stamp)
            # In-place stamp for engine-generated artifacts (heredoc/cat>file
            # output that has no src/ counterpart, e.g. Dockerfile.native).
            [ $# -ge 2 ] && [ $# -le 3 ] || { echo "usage: $0 stamp <file> [virtual_src]" >&2; exit 2; }
            stamp_header_inplace "$2" "${3:-}"
            ;;
        *)
            echo "usage: $0 {file|tree|stamp} ..." >&2
            exit 2
            ;;
    esac
fi
