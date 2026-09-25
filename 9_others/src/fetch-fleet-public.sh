#!/bin/sh
# Fetch just the dotfile paths of every PUBLIC fleet repo into <dest>/<dir>/, so
# the fleet guard can run where CI has no checkout of them (and no token for the
# private ones). Usage: fetch-fleet-public.sh <manifest.json> <dest>
#
# Sparse + blob-less: cloud-u-android alone is 13k files; the guard needs five paths.
# Private repos and `ci_skip` repos are named on stdout and left out — a skip is
# said out loud, never silent.
set -e
MANIFEST="$1"; DEST="$2"
[ -f "$MANIFEST" ] && [ -n "$DEST" ] || { echo "usage: fetch-fleet-public.sh <manifest.json> <dest>" >&2; exit 2; }
mkdir -p "$DEST"
node -e '
const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const paths = [...Object.values(m.targets || {}).map(t => "/" + t + "/"), ...Object.values(m.root_targets || {}).map(t => "/" + t), ...(m.fleet.module_mirrors || []).map(x => "/" + x.to + "/")];
for (const r of m.fleet.repos) console.log([r.dir, r.github, r.private ? "private" : "public", r.ci_skip ? "skip" : "", [...new Set(paths)].join(" ")].join("\t"));
' "$MANIFEST" | while IFS="$(printf '\t')" read -r dir gh vis skip paths; do
    [ "$vis" = public ] || { echo "fetch-fleet-public: $dir skipped (private — CI has no token)"; continue; }
    [ -z "$skip" ] || { echo "fetch-fleet-public: $dir skipped (ci_skip in manifest)"; continue; }
    GIT_LFS_SKIP_SMUDGE=1 git clone -q --depth 1 --filter=blob:none --sparse --no-checkout "https://github.com/diegonmarcos/$gh.git" "$DEST/$dir"
    # shellcheck disable=SC2086  # $paths is a space-separated list by construction
    git -C "$DEST/$dir" sparse-checkout set --no-cone $paths
    git -C "$DEST/$dir" checkout -q
    echo "fetch-fleet-public: $dir fetched"
done
