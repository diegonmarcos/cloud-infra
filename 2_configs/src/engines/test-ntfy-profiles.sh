#!/usr/bin/env bash
# test-ntfy-profiles.sh — validate ntfy RSS profile resolution (build.json → consolidated).
#
# Data-driven: reads bc-obs_ntfy/build.json (SoT for topics + profiles) and the
# emitted _cloud-data-consolidated.json (configs.ntfy.profiles). Asserts that:
#   1. every profile resolved to the RIGHT channel set (categories → topics, or
#      explicit topics list), by recomputing the resolution from build.json and
#      comparing to what the derive engine emitted;
#   2. each profile carries a /feed/<id>.atom URL and each channel a /feed/c/<name>.atom;
#   3. every channel name is a real topic (no dangling references);
#   4. the special.ntfy Caddy route exposes a gateway_upstream (so /feed* routes).
#
# Pure + reproducible: no network, no token. Exits non-zero on any mismatch.

set -uo pipefail
FAILS=0

REPO="${GIT_BASE:-$HOME/git}"
CLOUD_DATA_DIR="${CLOUD_DATA_DIR:-$REPO/cloud/2_configs/dist}"
BUILD_JSON="$REPO/cloud/a_solutions/infra-obs_ntfy/build.json"
CONSOLIDATED="$CLOUD_DATA_DIR/_cloud-data-consolidated.json"

err() { echo "✗ $*" >&2; FAILS=$((FAILS + 1)); }
ok()  { echo "✓ $*"; }

[ -f "$BUILD_JSON" ]    || { err "build.json missing at $BUILD_JSON"; exit 1; }
[ -f "$CONSOLIDATED" ]  || { err "consolidated missing at $CONSOLIDATED (run 2_configs/build.sh consolidate)"; exit 1; }

# ── 1. Profile → channel resolution recomputed from build.json ────────────────
# For each profile: expected channels = topics matching .categories, OR the
# explicit .topics list. Compare (sorted) to configs.ntfy.profiles[].channels.
mapfile -t PROFILE_IDS < <(jq -r '.profiles[].id' "$BUILD_JSON")
[ "${#PROFILE_IDS[@]}" -gt 0 ] || err "no profiles[] in build.json"

for PID in "${PROFILE_IDS[@]}"; do
  # Expected: resolve from build.json topics/categories.
  EXPECTED=$(jq -r --arg id "$PID" '
    . as $root
    | $root.profiles[] | select(.id==$id) as $p
    | ($p.topics // null) as $explicit
    | ($p.categories // []) as $cats
    | [ $root.topics[]
        | select( if $explicit != null then (.name as $n | $explicit | index($n))
                  else (.category as $c | $cats | index($c)) end )
        | .name ] | sort | join(",")
  ' "$BUILD_JSON")

  # Actual: what the derive engine emitted into the consolidated.
  ACTUAL=$(jq -r --arg id "$PID" '
    (.configs.ntfy.profiles // []) | .[] | select(.id==$id)
    | [ .channels[].name ] | sort | join(",")
  ' "$CONSOLIDATED")

  if [ -z "$ACTUAL" ]; then
    err "profile '$PID' missing from consolidated configs.ntfy.profiles"
  elif [ "$EXPECTED" = "$ACTUAL" ]; then
    N=$(awk -F, '{print NF}' <<<"$ACTUAL"); [ "$ACTUAL" = "" ] && N=0
    ok "profile '$PID' resolves to $N channels: [$ACTUAL]"
  else
    err "profile '$PID' channel mismatch — expected [$EXPECTED] got [$ACTUAL]"
  fi
done

# ── 2. Feed URL shape ─────────────────────────────────────────────────────────
BAD_PROFILE_FEED=$(jq -r '
  (.configs.ntfy.profiles // [])
  | map(select(.feed != ("/feed/" + .id + ".atom"))) | length
' "$CONSOLIDATED")
[ "$BAD_PROFILE_FEED" = "0" ] && ok "all profile feed URLs are /feed/<id>.atom" \
  || err "$BAD_PROFILE_FEED profile(s) have wrong feed URL shape"

BAD_CHAN_FEED=$(jq -r '
  [ (.configs.ntfy.profiles // [])[].channels[]
    | select(.feed != ("/feed/c/" + .name + ".atom")) ] | length
' "$CONSOLIDATED")
[ "$BAD_CHAN_FEED" = "0" ] && ok "all channel feed URLs are /feed/c/<name>.atom" \
  || err "$BAD_CHAN_FEED channel(s) have wrong feed URL shape"

# ── 3. No dangling channels (every channel name is a real topic) ──────────────
DANGLING=$(jq -r --slurpfile b "$BUILD_JSON" '
  ($b[0].topics | map(.name)) as $topics
  | [ (.configs.ntfy.profiles // [])[].channels[].name | select(. as $n | ($topics | index($n)) | not) ]
  | unique | join(",")
' "$CONSOLIDATED")
[ -z "$DANGLING" ] && ok "no dangling channels — every channel is a declared topic" \
  || err "channels reference non-existent topics: [$DANGLING]"

# ── 4. Caddy gateway route present (in the DERIVED build-caddy.json) ──────────
# build-caddy.json is what Caddy actually consumes; special.ntfy.gateway_upstream
# must resolve to <wg_ip>:<rss_gateway_port> or /feed* has no upstream (502).
CADDY_JSON="$CLOUD_DATA_DIR/build-caddy.json"
GW_PORT=$(jq -r '.declared_ports.rss_gateway // .ports.rss_gateway // empty' "$BUILD_JSON")
if [ ! -f "$CADDY_JSON" ]; then
  err "build-caddy.json missing at $CADDY_JSON"
else
  GW=$(jq -r '.special.ntfy.gateway_upstream // empty' "$CADDY_JSON")
  if [ -z "$GW" ] || [ "$GW" = "null" ]; then
    err "build-caddy.json special.ntfy.gateway_upstream is null/missing — /feed* has no upstream"
  elif [ -n "$GW_PORT" ] && [[ "$GW" != *":$GW_PORT" ]]; then
    err "gateway_upstream '$GW' does not end in gateway port :$GW_PORT"
  else
    ok "build-caddy.json special.ntfy.gateway_upstream = $GW (/feed* → rss-gateway)"
  fi
fi

echo "----"
[ "$FAILS" -eq 0 ] && { echo "ntfy-profiles: ALL PASS"; exit 0; }
echo "ntfy-profiles: $FAILS failure(s)"; exit 1
