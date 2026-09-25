#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ dotfiles FLEET — one declaration → the same dotfiles in EVERY repo ║
# ║                                                                  ║
# ║ Usage: deploy-dotfiles-fleet.sh [--check] [--require-all]        ║
# ║          <apps-src-dir> <dotfiles-dist-dir> <git-base>           ║
# ╚══════════════════════════════════════════════════════════════════╝
#
# deploy-dotfiles.sh puts the dotfiles into ONE repo. This puts them into all
# of them, from the same dist/dotfiles/ tree, driven by manifest.json:fleet.
# Before it existed the hop into every other repo was a hand copy, and the
# fleet diverged: 8, 9 and 11 servers in .mcp.json depending on when each repo
# was last touched, and cloud-data-my-ai-memory had none at all (#569) — its
# sessions saw a stale list without cloud-infra-mcp.
#
# Default mode EMITS (copies managed files into each repo that is checked out).
# --check emits nothing and exits 1 on any drift: the same comparison, so the
# guard and the emitter can never disagree about what "in sync" means.
#
# A repo that is not checked out under <git-base> is SKIPPED loudly, because CI
# cannot fetch the private ones. --require-all turns that skip into a failure,
# for the one place that must have every repo (the emitting agent/laptop).
#
# Additive per file, like the single-repo deploy: only files present in dist
# are written or compared; other files in .claude/ .vscode/ .obsidian/ are
# machine state and never touched. A symlink where a managed file belongs is
# drift — it dangles off the machine that made it — and is replaced.
#
# POSIX sh + node (JSON only), same as deploy-dotfiles.sh.

set -e

CHECK=0; REQUIRE_ALL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK=1; shift ;;
        --require-all) REQUIRE_ALL=1; shift ;;
        *) break ;;
    esac
done

DF_SRC="$1"; DF_DIST="$2"; BASE="$3"
[ -n "$DF_SRC" ] && [ -n "$DF_DIST" ] && [ -n "$BASE" ] || {
    echo "usage: deploy-dotfiles-fleet.sh [--check] [--require-all] <apps-src-dir> <dotfiles-dist-dir> <git-base>" >&2
    exit 2; }

MANIFEST="$DF_SRC/manifest.json"
[ -f "$MANIFEST" ] || { echo "FATAL: $MANIFEST missing" >&2; exit 1; }
[ -d "$DF_DIST" ]  || { echo "FATAL: $DF_DIST missing — run the dotfiles build first" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FATAL: node not found — required to read $MANIFEST" >&2; exit 1; }

# One reader, one place. Emits TSV lines; a missing key is FATAL, never empty,
# so a manifest without `fleet` cannot pass as "no repos, all in sync".
mf() { node -e '
const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const f = m.fleet;
if (!f || !Array.isArray(f.repos) || f.repos.length === 0) { console.error("FATAL: manifest.json has no fleet.repos"); process.exit(1); }
const q = process.argv[2];
if (q === "repos") for (const r of f.repos) console.log(r.dir);
if (q === "pairs") {
  // <dist subdir>/<file> -> <repo-relative path>, for directory targets and the fleet-wide root files
  for (const [tool, target] of Object.entries(m.targets || {})) console.log("dir\t" + tool + "\t" + target);
  for (const rf of f.root_files || []) console.log("root\t" + rf + "\t" + m.root_targets[rf]);
}
if (q === "sources") { const r = f.repos.find(x => x.dir === process.argv[3]); if (r && r.sources) for (const [dot, name] of Object.entries(r.sources.map)) console.log(r.sources.prefix + "\t" + dot + "\t" + name); }
if (q === "mirrors") for (const x of f.module_mirrors || []) console.log(x.from + "\t" + x.to + "\t" + (x.only ? x.only.join(" ") : "-"));
' "$MANIFEST" "$@"; }

SELF="$(cd "$DF_SRC/.." && pwd -P)"   # the repo that owns the declaration: it is the source, not a mirror target
TAB="$(printf '\t')"
LOG="$(mktemp)"; trap 'rm -f "$LOG"' EXIT   # findings, one per line — counted at the end (sync runs in pipe subshells)

# note <state> <repo> <path>
note() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$LOG"; }

# sync <src-file> <dest-file> <repo> <label>
sync() {
    _s="$1"; _d="$2"; _r="$3"; _l="$4"
    if [ -L "$_d" ]; then _st=SYMLINK
    elif [ ! -e "$_d" ]; then _st=MISSING
    elif ! cmp -s "$_s" "$_d"; then _st=DRIFT
    else return 0; fi
    if [ "$CHECK" = 1 ]; then
        note "$_st" "$_r" "$_l"
    else
        [ -L "$_d" ] && rm -f "$_d"
        mkdir -p "$(dirname "$_d")"
        cp -f "$_s" "$_d"
        if [ -x "$_s" ]; then chmod +x "$_d"; fi
        note "WROTE" "$_r" "$_l ($_st)"
    fi
}

# files_of <dir> — every file under it, relative
files_of() { (cd "$1" && find . -type f | sed 's|^\./||' | sort); }

# Read into a variable FIRST: a failing `mf` inside `for x in $(mf ...)` does not trip
# set -e, so an unreadable/fleet-less manifest would look like "0 repos, all in sync".
REPOS="$(mf repos)" || exit 1

checked=0; absent=0
for repo in $REPOS; do
    root="$BASE/$repo"
    if [ ! -d "$root" ]; then
        note ABSENT "$repo" "(not checked out under $BASE)"
        absent=$((absent + 1)); continue
    fi
    checked=$((checked + 1))

    mf pairs | while IFS="$TAB" read -r kind name target; do
        if [ "$kind" = dir ]; then
            [ -d "$DF_DIST/$name" ] || continue
            files_of "$DF_DIST/$name" | while read -r rel; do
                sync "$DF_DIST/$name/$rel" "$root/$target/$rel" "$repo" "$target/$rel"
            done
        else
            [ -f "$DF_DIST/root/$name" ] || continue
            sync "$DF_DIST/root/$name" "$root/$target" "$repo" "$target"
        fi
    done

    # Repos that generate their root dotfiles from a source tree of their own
    # (manifest fleet.repos[].sources): write the same files into that source too.
    # A managed path .claude/x maps to <prefix>/<map[.claude]>/x; .mcp.json to <prefix>/<map[.mcp.json]>.
    mf sources "$repo" | while IFS="$TAB" read -r prefix dot name; do
        case "$dot" in
            .mcp.json) if [ -f "$DF_DIST/root/mcp.json" ]; then sync "$DF_DIST/root/mcp.json" "$root/$prefix/$name" "$repo" "$prefix/$name"; fi ;;
            *) tool="${dot#.}"
               [ -d "$DF_DIST/$tool" ] || continue
               files_of "$DF_DIST/$tool" | while read -r rel; do
                   sync "$DF_DIST/$tool/$rel" "$root/$prefix/$name/$rel" "$repo" "$prefix/$name/$rel"
               done ;;
        esac
    done

    # Module copies — only where the destination dir already exists, and never in
    # the repo that owns the declaration (its own module IS the source).
    [ "$(cd "$root" && pwd -P)" = "$SELF" ] && continue
    mf mirrors | while IFS="$TAB" read -r from to only; do
        [ -d "$DF_DIST/$from" ] && [ -d "$root/$to" ] || continue
        files_of "$DF_DIST/$from" | while read -r rel; do
            case " $only " in *" $rel "*) ;; *) [ "$only" = "-" ] || continue ;; esac
            sync "$DF_DIST/$from/$rel" "$root/$to/$rel" "$repo" "$to/$rel"
        done
    done
done

cat "$LOG"
drift=$(grep -c -E '^(SYMLINK|MISSING|DRIFT)' "$LOG" || true)
wrote=$(grep -c '^WROTE' "$LOG" || true)
[ "$REQUIRE_ALL" = 1 ] && [ "$absent" -gt 0 ] && { echo "FAIL: --require-all and $absent repo(s) not checked out" >&2; exit 1; }
if [ "$CHECK" = 1 ]; then
    echo "fleet dotfiles: $checked repo(s) checked, $absent absent, $drift drifted file(s)"
    [ "$drift" -eq 0 ] || { echo "FAIL: dotfiles drift — run 9_others/build.sh fleet, then commit each repo" >&2; exit 1; }
else
    echo "fleet dotfiles: $checked repo(s), $wrote file(s) written, $absent absent"
fi
