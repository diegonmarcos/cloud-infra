#!/usr/bin/env bash
# test-url-scheme.sh — guard the fleet URL scheme (a0_docs/eng-specs/url-scheme.md).
#
#   PUBLIC : {app}.diegonmarcos.com   — one per publicly routed service, every
#            Authelia-gated vhost carries a GitHub Pages landing fallback.
#   PRIVATE: cloud.{name}.app         — exactly one per routable service, mesh
#            only: never in a public route, the public-edge allowlist, the
#            public DNS zone (Cloudflare) or the hub's diegonmarcos.com zone.
#
# Reads only derived dist/ + declared sources. Read-only; exits non-zero on
# the first class of violation it finds (all violations of that class listed).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUD="$(cd "$HERE/../../.." && pwd)"
DIST="$CLOUD/1_cloud-configs/dist"
CADDY="$DIST/build-caddy.json"
EDGE="$DIST/build-caddy-public.json"
CONS="$DIST/_cloud-data-consolidated.json"
CF_DIR="$CLOUD/c_vps/ba-clo_cloudflare/src"
PRIV_RE='^cloud\.[a-z0-9][a-z0-9-]*\.app$'
PUB_RE='^[a-z0-9][a-z0-9-]*\.diegonmarcos\.com$'

fail=0
bad() { echo "✗ $*" >&2; fail=1; }
ok()  { echo "✓ $*"; }
for f in "$CADDY" "$CONS"; do [ -f "$f" ] || { echo "✗ $f missing — run build.sh all first" >&2; exit 1; }; done

# 1) every private mesh name is well-formed and unique
badp=$(jq -r --arg re "$PRIV_RE" '.private_mesh_routes[]?.service | select(test($re)|not)' "$CADDY")
[ -z "$badp" ] && ok "private_mesh_routes: all names are cloud.<name>.app" || bad "malformed private names: $badp"
dupp=$(jq -r '[.private_mesh_routes[]?.service] | group_by(.) | map(select(length>1)[0])[]' "$CADDY")
[ -z "$dupp" ] && ok "private_mesh_routes: no duplicates" || bad "duplicate private names: $dupp"

# 2) every routable service (an internal .app route) has exactly ONE private name
missing=$(jq -r '.internal_routes[] | select(.service|test("^[a-z0-9-]+\\.app$")) | select((.private_name // "") == "") | .service' "$CADDY")
[ -z "$missing" ] && ok "internal_routes: every <name>.app service has a cloud.<name>.app private name" || bad "services without a private name: $missing"

# 3) every publicly routed service declares at most ONE {app}.diegonmarcos.com
multi=$(jq -r --arg re "$PUB_RE" '.services | to_entries[] | .value.proxy.primary.domain? // empty | select(type=="string") | select(test($re)|not) | select(test("diegonmarcos\\.com"))' "$CONS")
[ -z "$multi" ] && ok "services: each public domain is a single {app}.diegonmarcos.com" || bad "non-conforming public domains: $multi"

# 4) no cloud.*.app anywhere public
leak=$(jq -r '[.routes[]?.domain, .path_routes[]?.parent_domain, .github_pages_proxies[]?.domain, .redirects[]?.from?, .well_known_routes[]?.target_domain] | map(select(type=="string")) | map(split(", ")[]) | map(select(test("(^|\\.)cloud\\.[^ ]*\\.app$")))[]' "$CADDY")
[ -z "$leak" ] && ok "build-caddy.json: no cloud.*.app on a public vhost" || bad "cloud.*.app on public vhost: $leak"
if [ -f "$EDGE" ]; then
  if grep -Eq 'cloud\.[a-z0-9-]+\.app' "$EDGE"; then bad "cloud.*.app present in the public-edge allowlist ($EDGE)"; else ok "build-caddy-public.json: no cloud.*.app"; fi
fi
if [ -d "$CF_DIR" ]; then
  if grep -rEq 'cloud\.[a-z0-9-]+\.app' "$CF_DIR"/*.tf "$CF_DIR"/*.json 2>/dev/null; then bad "cloud.*.app in Cloudflare (public DNS) sources"; else ok "Cloudflare sources: no cloud.*.app"; fi
fi
pubzone=$(jq -r '.services | to_entries[] | .value.dns_records? // empty' "$CONS" 2>/dev/null | grep -E 'cloud\.[a-z0-9-]+\.app' || true)
[ -z "$pubzone" ] || bad "cloud.*.app in a declared public DNS record: $pubzone"

# 5) every Authelia-gated vhost has a landing page under the declared base
base=$(jq -r '.public_landing.base_url // empty' "$CADDY")
if [ -n "$base" ]; then
  noland=$(jq -r '.routes[] | select(.auth != "none") | select(.landing == null) | .domain' "$CADDY" \
    | grep -vE '^(auth|rss)\.diegonmarcos\.com$' || true)
  # auth (Authelia itself, auth:bypass) and rss (ntfy 3-tier) deliberately keep their own flows
  [ -z "$noland" ] && ok "every gated vhost carries a landing fallback" || bad "gated vhosts without landing: $noland"
  offbase=$(jq -r --arg b "$base" '.routes[] | select(.landing) | select(.landing|startswith($b)|not) | .domain' "$CADDY")
  [ -z "$offbase" ] && ok "every landing is under $base" || bad "landing outside base: $offbase"
fi

exit $fail
