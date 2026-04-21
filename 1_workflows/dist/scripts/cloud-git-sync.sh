#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ cloud-git-sync.sh — smart, non-destructive `git sync`            ║
# ║                                                                  ║
# ║ Source: cloud/1_workflows/src/scripts/cloud-git-sync.sh          ║
# ║ Wired : 1_workflows/src/gitconfig  →  [alias] sync               ║
# ║                                                                  ║
# ║ Usage:                                                           ║
# ║   git sync              # default: remote wins on conflict       ║
# ║   git sync remote       # origin/main wins on conflict           ║
# ║   git sync local        # local commits win on conflict          ║
# ║                                                                  ║
# ║ Flow:                                                            ║
# ║   1. stash any dirty work (autosaved, named + timestamped)       ║
# ║   2. fetch origin                                                ║
# ║   3. rebase local commits onto origin/main using -X theirs|ours  ║
# ║   4. pop stash                                                   ║
# ║   5. submodule update --init --recursive --remote --rebase       ║
# ║                                                                  ║
# ║ On any rebase/stash-pop halt, the repo is left in a resumable    ║
# ║ state with a clear recovery banner printed to stderr.            ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eu

MODE="${1:-remote}"
case "$MODE" in
  remote) STRATEGY="theirs" ;;
  local)  STRATEGY="ours"   ;;
  *)
    printf 'usage: git sync {remote|local}\n' >&2
    exit 2
    ;;
esac

log() { printf '[sync] %s\n' "$1"; }
warn() { printf '[sync] %s\n' "$1" >&2; }

banner() {
  printf '%s\n' "$1" >&2
}

log "mode=$MODE (on conflict, $MODE wins)"

# ── 1. stash any dirty state ────────────────────────────────────────
STASHED=0
if ! git diff --quiet \
   || ! git diff --cached --quiet \
   || [ -n "$(git ls-files --others --exclude-standard)" ]; then
  STASH_MSG="pre-sync $(date -u +%FT%TZ)"
  if git stash push -u -m "$STASH_MSG" >/dev/null; then
    STASHED=1
    log "stashed dirty tree as: $STASH_MSG"
  else
    warn "git stash push failed — aborting sync"
    exit 1
  fi
fi

# ── 2. fetch origin ─────────────────────────────────────────────────
log "fetching origin..."
git fetch origin

# ── 3. rebase onto origin/main with conflict strategy ───────────────
log "rebasing local commits onto origin/main (-X $STRATEGY)..."
if ! git rebase -X "$STRATEGY" origin/main; then
  banner "
╔══════════════════════════════════════════════════════════════════╗
║ REBASE HALTED                                                    ║
║                                                                  ║
║ rebase -X $STRATEGY was not enough — a structural conflict remains.    ║
║ Resolve in-place:                                                ║
║    edit conflicted files    git add <files>                      ║
║    git rebase --continue                                         ║
║                                                                  ║
║ Or abandon the attempt:                                          ║
║    git rebase --abort                                            ║
║                                                                  ║
║ Your stashed dirty work (if any) is at stash@{0}.                ║
╚══════════════════════════════════════════════════════════════════╝"
  exit 1
fi

# ── 4. pop stash ────────────────────────────────────────────────────
if [ "$STASHED" = 1 ]; then
  log "reapplying stashed dirty tree..."
  if ! git stash pop >/dev/null; then
    banner "
╔══════════════════════════════════════════════════════════════════╗
║ STASH POP CONFLICT                                               ║
║                                                                  ║
║ The dirty work you had before sync conflicts with rebased tree.  ║
║ Stash is preserved at stash@{0}. Resolve manually:               ║
║    git checkout --theirs <file>    (keep rebased version)        ║
║    git checkout --ours <file>      (keep stashed version)        ║
║    git add <file> && git stash drop stash@{0}                    ║
╚══════════════════════════════════════════════════════════════════╝"
    exit 1
  fi
fi

# ── 5. refresh submodules (pointer from parent + files from upstream)
log "updating submodules (--init --recursive --remote --rebase)..."
git submodule update --init --recursive --remote --rebase

log "done."
