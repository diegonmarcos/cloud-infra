#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Workflow engine tester — every dist/ artifact is header-stamped  ║
# ║                                                                  ║
# ║ Proves:                                                          ║
# ║   Every text artifact built by                                   ║
# ║   1_configs/src/deploy/scripts/cloud-ship-repo-workflow-engine.sh     ║
# ║   carries the "GENERATED FILE — DO NOT EDIT" banner defined in   ║
# ║   1_configs/src/engine/libs/generated-header.json.                    ║
# ║                                                                  ║
# ║ Covers: dist/*.yml, dist/scripts/, dist/hooks/, dist/test/,      ║
# ║         dist/.gitignore, dist/.gitmodules, dist/gitconfig, and   ║
# ║         the deployed copies (.github/workflows/, repo-root dot-  ║
# ║         files). JSON artifacts: asserts `_generated` root key.   ║
# ║                                                                  ║
# ║ Usage: bash 1_configs/src/deploy/test/test_generated_header_present.sh║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

# Repo root by upward search, not a fixed ../../.. — this file exists at BOTH
# 1_configs/src/deploy/test/ and 1_configs/dist/test/ (generated), which sit at
# different depths, so one literal count is wrong for one of the two copies.
REPO_ROOT="$(_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
DIST="$REPO_ROOT/1_configs/dist"
HEADER_JSON="$REPO_ROOT/1_configs/src/engine/libs/generated-header.json"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

MARKER="$(jq -r '.marker' "$HEADER_JSON")"
if [ -z "$MARKER" ] || [ "$MARKER" = "null" ]; then
    fail "Could not read .marker from $HEADER_JSON"
    exit 1
fi

# A dist file should carry the banner if its extension/basename maps to a
# comment prefix in generated-header.json. This function returns 0 iff the
# file is expected to be stamped.
expects_stamp() {
    local path="$1"
    local base ext
    base="$(basename "$path")"
    ext="${base##*.}"
    # skip_extensions → no stamp
    if jq -er --arg b "$base" '(.skip_basenames // [])[] | select(. == $b)' "$HEADER_JSON" >/dev/null 2>&1; then
        return 1
    fi
    if jq -er --arg b "$base" '.skip_extensions[] | select(. as $e | $b | endswith("." + $e))' "$HEADER_JSON" >/dev/null 2>&1; then
        return 1
    fi
    # JSON → plain-copied by default (no stamp expected unless INJECT_JSON=1)
    if [ "$ext" = "json" ]; then
        [ "${INJECT_JSON:-0}" = "1" ] && return 2 || return 1
    fi
    # basename match?
    if [ -n "$(jq -r --arg n "$base" '.comment_by_basename[$n] // empty' "$HEADER_JSON")" ]; then
        return 0
    fi
    # extension match?
    if [ "$ext" != "$base" ] && [ -n "$(jq -r --arg e "$ext" '.comment_by_ext[$e] // empty' "$HEADER_JSON")" ]; then
        return 0
    fi
    return 1
}

# Check a single file.
check_file() {
    local f="$1"
    local rel="${f#$REPO_ROOT/}"
    set +e
    expects_stamp "$f"
    local rc=$?
    set -e
    case "$rc" in
        0)
            if head -n 15 "$f" | grep -qF "$MARKER"; then
                pass "$rel"
            else
                fail "$rel — missing '$MARKER' in first 15 lines"
            fi
            ;;
        2)
            # JSON: require `_generated` root key.
            if jq -e 'has("_generated")' "$f" >/dev/null 2>&1; then
                pass "$rel (JSON _generated key present)"
            else
                fail "$rel — JSON lacks `_generated` root key"
            fi
            ;;
        *)
            # unknown/skip — tester stays silent (no stamp expected)
            ;;
    esac
}

echo "── dist/ artifacts must carry the GENERATED-FILE banner ──"
while IFS= read -r -d '' f; do check_file "$f"; done < <(find "$DIST" -type f -print0)

echo ""
echo "── deployed copies (.github/workflows, repo-root dotfiles) ──"
for f in "$REPO_ROOT/.github/workflows/"*.yml \
         "$REPO_ROOT/.github/workflows/scripts/"*.sh \
         "$REPO_ROOT/.github/workflows/hooks/"* \
         "$REPO_ROOT/.gitignore" \
         "$REPO_ROOT/.gitmodules"; do
    [ -f "$f" ] || continue
    check_file "$f"
done

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "══════════════════════════════════════════════"
    echo "generated-header presence: PASS"
    echo "══════════════════════════════════════════════"
    exit 0
else
    echo "══════════════════════════════════════════════"
    echo "generated-header presence: FAIL"
    echo "══════════════════════════════════════════════"
    exit 1
fi
