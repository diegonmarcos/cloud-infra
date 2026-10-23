#!/bin/sh
# Thin wrapper. The implementation moved to cloud-u-linux (my-ai engine
# `dotfiles`): da_my-ai/engines/dotfiles/deploy-dotfiles.sh. my-ai is the single
# deployer of Claude config; this path stays so build.sh, CI and the generated
# file banners ("Engine : 9_others/src/deploy-dotfiles.sh") keep working.
#
# Usage: deploy-dotfiles.sh <dotfiles-src-dir> <dist-dir> <repo-root>
#
# Resolution order for the canonical copy:
#   $MY_AI_DOTFILES_SCRIPT, the CLAUDE_SOT_DIR checkout, ~/git/cloud-u-linux,
#   a cloud-u-linux sibling of this repo, the `my-ai` binary on PATH, and last
#   a shallow clone (what lint-pipeline does for the claude SoT).
# No SoT env is invented here: the engine's own default decides whether the
# claude/ refresh runs, exactly as before.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
export INJECT_HEADER="${INJECT_HEADER:-$HERE/inject-header.sh}"
REL=da_my-ai/engines/dotfiles/deploy-dotfiles.sh

S=""
for c in "${MY_AI_DOTFILES_SCRIPT:-}" \
         "${CLAUDE_SOT_DIR:+$CLAUDE_SOT_DIR/../../engines/dotfiles/deploy-dotfiles.sh}" \
         "$HOME/git/cloud-u-linux/$REL" \
         "$HERE/../../../cloud-u-linux/$REL"; do
    [ -n "$c" ] && [ -f "$c" ] && { S="$c"; break; }
done
if [ -n "$S" ]; then exec sh "$S" "$@"; fi
if command -v my-ai >/dev/null 2>&1; then exec my-ai engine run dotfiles -- "$@"; fi

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
echo "deploy-dotfiles: no my-ai engine found locally - shallow-cloning cloud-u-linux" >&2
git clone -q --depth 1 https://github.com/diegonmarcos/cloud-u-linux.git "$T/cloud-u-linux" \
    || { echo "FATAL: cannot obtain the dotfiles engine from cloud-u-linux" >&2; exit 1; }
sh "$T/cloud-u-linux/$REL" "$@"
