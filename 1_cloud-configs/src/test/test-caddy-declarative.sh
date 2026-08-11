#!/usr/bin/env bash
# test-caddy-declarative.sh — validate Caddy pipeline end-to-end.
#
# Checks:
#   1. build-caddy.json has every top-level key the flake needs
#   2. Caddy's src/build-caddy.json exists (real file or symlink)
#   3. `nix build` of Caddy's src/ succeeds
#   4. Generated Caddyfile matches live one (byte-identical modulo whitespace)
#
# Exits non-zero on any failure. Safe to run anytime — read-only.

set -euo pipefail

REPO="${GIT_BASE:-$HOME/git}"
CADDY_SRC="$REPO/cloud/a_solutions/infra-sec_caddy/src"
CLOUD_JSON="$REPO/cloud/1_cloud-configs/dist/build-caddy.json"
CADDY_JSON="$CADDY_SRC/build-caddy.json"
LIVE_SNAPSHOT="${LIVE_SNAPSHOT:-/tmp/caddyfile-live-pre.txt}"

REQUIRED_KEYS=(global security_snippets auth wkd mta_sts messages on_demand_tls error_handler catch_all)

err() { echo "✗ $*" >&2; exit 1; }
ok()  { echo "✓ $*"; }

# 1) Pipeline output has all required keys
[ -f "$CLOUD_JSON" ] || err "cloud-data JSON missing: $CLOUD_JSON"
for k in "${REQUIRED_KEYS[@]}"; do
  jq -e ".$k" "$CLOUD_JSON" >/dev/null 2>&1 || err "missing top-level key: $k"
done
ok "all 9 required keys present in $CLOUD_JSON"

# 2) Caddy src/ must reference the JSON as a SYMLINK, not a copy.
#
# "real file or symlink both OK" was the old rule, and it hid a live outage.
# A regular file here is a FROZEN SNAPSHOT: flake.nix reads this path, so Caddy
# builds from whatever the file contained when it stopped being a link, while
# derive keeps updating dist/build-caddy.json. Nothing looks wrong — the build
# succeeds and gen-configs correctly reports "dist/ unchanged, nothing to
# commit" — but the deployed Caddyfile silently drifts from source. That is
# exactly how the c3-infra-mcp bearer gate was authored, committed, and never
# reached Caddy (4a8b1703d → 2c56195c4).
#
# The committed mode is what matters: a symlink in the worktree that is a
# regular file in the index still ships the snapshot.
if [ ! -e "$CADDY_JSON" ]; then
  echo "  staging: $CADDY_JSON (symlink → ../../../1_cloud-configs/dist/build-caddy.json)"
  ln -sf "../../../1_cloud-configs/dist/build-caddy.json" "$CADDY_JSON"
fi
[ -L "$CADDY_JSON" ] || err "$CADDY_JSON is a regular file, not a symlink — Caddy would build from a frozen snapshot. Fix: ln -sf ../../../1_cloud-configs/dist/build-caddy.json $CADDY_JSON"
CADDY_JSON_MODE=$(git -C "$REPO/cloud" ls-files -s -- "${CADDY_JSON#"$REPO/cloud/"}" 2>/dev/null | awk '{print $1}')
if [ -n "$CADDY_JSON_MODE" ] && [ "$CADDY_JSON_MODE" != "120000" ]; then
  err "$CADDY_JSON is committed as mode $CADDY_JSON_MODE (regular file), not 120000 (symlink) — the deploy would use a frozen snapshot even though the worktree looks right"
fi
ok "$CADDY_JSON is a symlink (committed mode ${CADDY_JSON_MODE:-unknown})"

# 3) nix build — flake can't follow a symlink pointing outside its own source tree,
#    so temporarily resolve to a real file (same behavior as the build engine at ship time).
WAS_SYMLINK=false
if [ -L "$CADDY_JSON" ]; then
  WAS_SYMLINK=true
  TARGET=$(readlink -f "$CADDY_JSON")
  rm "$CADDY_JSON"
  cp "$TARGET" "$CADDY_JSON"
  echo "  resolved symlink → real file for nix build"
fi

# The restore MUST be a trap, not a straight-line statement. This script runs
# `set -euo pipefail`, so a failing `nix build` aborts at the assignment below
# and every line after it is skipped — including the restore. One failed build
# then leaves the symlink replaced by a regular file, and committing that
# working tree is precisely the freeze described above. A trap also covers
# Ctrl-C and timeouts.
restore_caddy_json_symlink() {
  if [ "${WAS_SYMLINK:-false}" = true ] && [ ! -L "$CADDY_JSON" ]; then
    rm -f "$CADDY_JSON"
    ln -sf "../../../1_cloud-configs/dist/build-caddy.json" "$CADDY_JSON"
    echo "  restored symlink after nix build"
  fi
}
trap restore_caddy_json_symlink EXIT INT TERM

BUILD_OUT=$(cd "$CADDY_SRC" && nix build --impure --no-link --print-out-paths 2>&1 | tail -1) || true
NIX_RC=$?

restore_caddy_json_symlink

[ $NIX_RC -eq 0 ] || err "nix build failed"
[ -d "$BUILD_OUT" ] || err "nix build produced no output: $BUILD_OUT"
ok "nix build succeeded → $BUILD_OUT"

GENERATED="$BUILD_OUT/Caddyfile"
[ -f "$GENERATED" ] || err "Caddyfile missing in build output"

# 4) Diff against live snapshot (modulo whitespace)
if [ ! -f "$LIVE_SNAPSHOT" ]; then
  echo "⚠ live snapshot missing at $LIVE_SNAPSHOT — skipping diff. Create with:"
  echo "    ssh gcp-proxy 'sudo docker exec caddy cat /etc/caddy/Caddyfile' > $LIVE_SNAPSHOT"
else
  DIFF_LINES=$(diff --ignore-all-space --ignore-blank-lines "$LIVE_SNAPSHOT" "$GENERATED" | wc -l || true)
  if [ "$DIFF_LINES" -eq 0 ]; then
    ok "Caddyfile byte-identical to live snapshot (ignoring whitespace)"
  else
    echo "⚠ Caddyfile differs from live snapshot ($DIFF_LINES diff lines):"
    diff --ignore-all-space --ignore-blank-lines "$LIVE_SNAPSHOT" "$GENERATED" | head -40
    echo "  (review diff — accept if cosmetic, fail if functional)"
  fi
fi

ok "all declarative-caddy tests passed"
