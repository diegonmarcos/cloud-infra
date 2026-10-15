#!/usr/bin/env bash
# test-url-scheme.sh — guard the fleet URL scheme (a0_docs/eng-specs/url-scheme.md).
#
#   APK       : cloud-{name}.diegonmarcos.com — public, NEVER wg_only, Authelia,
#               anonymous -> landing. Private cloud-{name}.app.
#   CONTAINER : c3-{container}.diegonmarcos.com — public name, wg_only (403
#               off-mesh). Private c3-{container}.app.
#   GROUPS    : SPECIAL (auth open, GitHub Pages), MAIL (open), NETWORK (vpn
#               wg_only).
#   LEGACY    : {app}.diegonmarcos.com and cloud.{name}.app keep working; the
#               gated ones carry a landing fallback. No .app name ever reaches a
#               public route, the public-edge allowlist or public DNS.
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
PRIV_RE='^cloud\.[a-z0-9][a-z0-9-]*\.app$'          # legacy private names
C3_RE='^c3-[a-z0-9][a-z0-9-]*\.app$'
APK_RE='^cloud-[a-z0-9][a-z0-9-]*\.app$'
ANY_PRIV_RE='(^|\.)((cloud\.[a-z0-9-]+)|(cloud-[a-z0-9-]+)|(c3-[a-z0-9-]+))\.app$'
PUB_RE='^[a-z0-9][a-z0-9-]*\.diegonmarcos\.com$'

fail=0
bad() { echo "✗ $*" >&2; fail=1; }
ok()  { echo "✓ $*"; }
for f in "$CADDY" "$CONS"; do [ -f "$f" ] || { echo "✗ $f missing — run build.sh all first" >&2; exit 1; }; done

# 1) every private mesh name is well-formed and unique
badp=$(jq -r --arg legacy "$PRIV_RE" --arg c3 "$C3_RE" --arg apk "$APK_RE" '.private_mesh_routes[]?
  | select((.scheme // "") as $k | .service | (if $k=="c3" then test($c3) elif $k=="apk" then test($apk) else test($legacy) end) | not) | .service' "$CADDY")
[ -z "$badp" ] && ok "private_mesh_routes: names are c3-<container>.app, cloud-<apk>.app or legacy cloud.<name>.app" || bad "malformed private names: $badp"
dupp=$(jq -r '[.private_mesh_routes[]?.service] | group_by(.) | map(select(length>1)[0])[]' "$CADDY")
[ -z "$dupp" ] && ok "private_mesh_routes: no duplicates" || bad "duplicate private names: $dupp"

# 2) every routable service (an internal .app route) has exactly ONE private name
missing=$(jq -r '.internal_routes[] | select(.service|test("^[a-z0-9-]+\\.app$")) | select((.private_name // "") == "") | .service' "$CADDY")
[ -z "$missing" ] && ok "internal_routes: every <name>.app service has a cloud.<name>.app private name" || bad "services without a private name: $missing"

# 3) every publicly routed service declares at most ONE {app}.diegonmarcos.com
multi=$(jq -r --arg re "$PUB_RE" '.services | to_entries[] | .value.proxy.primary.domain? // empty | select(type=="string") | select(test($re)|not) | select(test("diegonmarcos\\.com"))' "$CONS")
[ -z "$multi" ] && ok "services: each public domain is a single {app}.diegonmarcos.com" || bad "non-conforming public domains: $multi"

# 4) no cloud.*.app anywhere public
leak=$(jq -r --arg re "$ANY_PRIV_RE" '[.routes[]?.domain, .path_routes[]?.parent_domain, .github_pages_proxies[]?.domain, .redirects[]?.from?, .well_known_routes[]?.target_domain] | map(select(type=="string")) | map(split(", ")[]) | map(select(test($re)))[]' "$CADDY")
[ -z "$leak" ] && ok "build-caddy.json: no private .app name on a public vhost" || bad "private .app name on public vhost: $leak"
if [ -f "$EDGE" ]; then
  if grep -Eq '"(cloud\.|cloud-|c3-)[a-z0-9-]+\.app"' "$EDGE"; then bad "private .app name present in the public-edge allowlist ($EDGE)"; else ok "build-caddy-public.json: no private .app name"; fi
fi
if [ -d "$CF_DIR" ]; then
  if grep -rEq '"?(cloud\.|cloud-|c3-)[a-z0-9-]+\.app"?' "$CF_DIR"/*.tf "$CF_DIR"/*.json 2>/dev/null; then bad "private .app name in Cloudflare (public DNS) sources"; else ok "Cloudflare sources: no private .app name"; fi
fi
pubzone=$(jq -r '.services | to_entries[] | .value.dns_records? // empty' "$CONS" 2>/dev/null | grep -E '(cloud\.|cloud-|c3-)[a-z0-9-]+\.app' || true)
[ -z "$pubzone" ] || bad "private .app name in a declared public DNS record: $pubzone"

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

# ── URL scheme v2: APK / container / groups ────────────────────────────
APKM="$CLOUD/../cloud-u-android/2_configs/apk-manifest.json"
MCPM="$CLOUD/a_solutions/_shared/mcp-manifest.json"
for f in "$APKM" "$MCPM"; do [ -f "$f" ] || { echo "✗ $f missing — check out the source repo" >&2; exit 1; }; done

# 6) APK hosts: generated from the manifest, public, NEVER wg_only
want=$(jq -r '.apps[].name | . + ".diegonmarcos.com"' "$APKM" | sort)
have=$(jq -r '.url_scheme.apk_hosts[].host' "$CADDY" | sort)
[ "$want" = "$have" ] && ok "APK hosts: exactly the apk-manifest.json apps ($(echo "$want" | wc -l))" || bad "APK hosts differ from apk-manifest.json: $(diff <(echo "$want") <(echo "$have") | tr '\n' ' ')"
apkwg=$(jq -r '.url_scheme.apk_hosts[].host as $h | .routes[] | select(.domain==$h) | select(.wg_only==true) | .domain' "$CADDY")
[ -z "$apkwg" ] && ok "no APK host is wg_only" || bad "APK hosts that are wg_only: $apkwg"
apkmiss=$(jq -r '.url_scheme.apk_hosts[].host as $h | select([.routes[]|select(.domain==$h)]|length==0) | $h' "$CADDY")
[ -z "$apkmiss" ] && ok "every APK host has a route" || bad "APK hosts without a route: $apkmiss"
apknl=$(jq -r '.routes[] | select(.apk) | select(.landing == null) | .domain' "$CADDY")
[ -z "$apknl" ] && ok "every APK host carries a landing redirect" || bad "APK hosts without landing: $apknl"
apkbad=$(jq -r '.routes[] | select(.apk) | select(.domain | test("^cloud-[a-z0-9-]+\\.diegonmarcos\\.com$") | not) | .domain' "$CADDY")
[ -z "$apkbad" ] && ok "APK hosts are cloud-<name>.diegonmarcos.com" || bad "malformed APK hosts: $apkbad"

# 7) container hosts: every c3-* public host is wg_only, auth none (403 off-mesh)
c3open=$(jq -r '.routes[] | select(.domain | test("^c3-[a-z0-9-]+\\.diegonmarcos\\.com$")) | select(.wg_only != true) | .domain' "$CADDY")
[ -z "$c3open" ] && ok "all c3-* public hosts are wg_only" || bad "c3-* hosts that are NOT wg_only: $c3open"
c3n=$(jq -r '[.routes[] | select(.domain | test("^c3-[a-z0-9-]+\\.diegonmarcos\\.com$"))] | length' "$CADDY")
c3d=$(jq -r '.url_scheme.container_hosts | length' "$CADDY")
[ "$c3n" = "$c3d" ] && [ "$c3n" -gt 0 ] && ok "c3-* routes match the declared container hosts ($c3n)" || bad "c3 route count $c3n != container_hosts $c3d"
c3nopriv=$(jq -r '. as $r | ([$r.private_mesh_routes[].service] + [$r.internal_routes[].service] + [$r.all_app_urls[].service]) as $all | $r.url_scheme.container_hosts[] | select(.private as $p | $all | index($p) | not) | .private' "$CADDY")
[ -z "$c3nopriv" ] && ok "every c3-* host has a served c3-<container>.app private name" || bad "c3 hosts without a private name: $c3nopriv"

# 8) groups
authwg=$(jq -r '.routes[] | select(.domain=="auth.diegonmarcos.com") | select(.wg_only==true) | .domain' "$CADDY")
[ -z "$authwg" ] && jq -e '.routes[]|select(.domain=="auth.diegonmarcos.com")' "$CADDY" >/dev/null && ok "auth.diegonmarcos.com is open (not wg_only)" || bad "auth.diegonmarcos.com is wg_only or missing"
# TODO(vpn-pending): vpn. stays at its previous exposure until the owner confirms
# they do not join the mesh via WireGuard-over-443 on vpn. (wg_only could lock
# them out). Re-enable this assertion once confirmed; groups.NETWORK.pending_wg_only.
echo "- SKIP (pending owner confirmation): vpn.diegonmarcos.com wg_only check — TODO re-enable"
# vpnwg=$(jq -r '.routes[] | select(.domain=="vpn.diegonmarcos.com") | .wg_only' "$CADDY")
# [ "$vpnwg" = "true" ] && ok "vpn.diegonmarcos.com is wg_only" || bad "vpn.diegonmarcos.com is not wg_only"
known=$(jq -r '[.routes[]?.domain, (.github_pages_proxies[]?.domain | split(", ")[]), .redirects[]?.domain, .l4_routes[]?.sni, .mta_sts.domain, (.l4_routes[]? | select(.sni==null and .port==443) | "imap.diegonmarcos.com")] | map(select(type=="string")) | .[]' "$CADDY" | sort -u)
openhosts=$(jq -r '.url_scheme.groups | to_entries[] | .value.open[]?' "$CADDY")
for h in $openhosts; do
  echo "$known" | grep -qxF "$h" || bad "group host $h is not served by any route"
  if jq -e --arg h "$h" '.routes[] | select(.domain==$h) | select(.wg_only==true)' "$CADDY" >/dev/null; then
    # wg_only vhost is only allowed when its well-known grafts stay public (mails., like jmap.)
    jq -e --arg h "$h" '.well_known_routes[] | select(.target_domain==$h)' "$CADDY" >/dev/null || bad "group host $h is open by declaration but wg_only"
  fi
done
[ "$fail" = 0 ] && ok "SPECIAL + MAIL group hosts are all served and open"
for h in $(jq -r '.url_scheme.groups.NETWORK.wg_only[]?' "$CADDY"); do
  jq -e --arg h "$h" '.routes[] | select(.domain==$h) | select(.wg_only==true)' "$CADDY" >/dev/null || bad "NETWORK host $h is not wg_only"
done
jq -e '.l4_routes[] | select(.port==25)' "$CADDY" >/dev/null && ok "MAIL: port 25 L4 route present" || bad "MAIL: port 25 L4 route missing"
jq -e '.well_known_routes[] | select(.path=="/.well-known/jmap" and .target_domain=="mails.diegonmarcos.com")' "$CADDY" >/dev/null && ok "MAIL: mails. serves /.well-known/jmap" || bad "MAIL: mails. has no /.well-known/jmap"

# 9) MCPs: every auth:"token" manifest MCP is token-gated (bearer_auth); auth:"mesh" (vault) is checked in 12)
mcpbad=$(jq -r --argjson m "$(jq '[.mcps[] | select(.auth=="token") | .base_path]' "$MCPM")" '[.mcp_routes[].endpoints[]] as $eps | $m[] as $bp | select(([$eps[]|select(.base_path==$bp and .bearer_auth==true)]|length)==0) | $bp' "$CADDY")
[ -z "$mcpbad" ] && ok "every token manifest MCP is public with token auth" || bad "MCPs without token auth: $mcpbad"

# 10) unknown subdomains land on the landing hub
cr=$(jq -r '.catch_all.redirect_to // empty' "$CADDY")
case "$cr" in "$base"*) ok "catch-all redirects unknown hosts to the landing hub";; *) bad "catch_all.redirect_to missing or outside landing base";; esac

# 11) additive: the legacy hostnames and shared hosts are all still routed
for h in api.diegonmarcos.com app.diegonmarcos.com analytics.diegonmarcos.com cloud.diegonmarcos.com; do
  jq -e --arg h "$h" '.path_routes[] | select(.parent_domain==$h)' "$CADDY" >/dev/null || bad "legacy shared host $h lost its routes"
done
jq -e '.mcp_routes[] | select(.parent_domain=="mcp.diegonmarcos.com")' "$CADDY" >/dev/null || bad "mcp.diegonmarcos.com lost"
for h in git matrix messenger webmail chat; do
  jq -e --arg h "$h.diegonmarcos.com" '.routes[] | select(.domain==$h)' "$CADDY" >/dev/null || bad "legacy host $h.diegonmarcos.com removed"
done
[ "$fail" = 0 ] && ok "legacy hostnames still routed"

# 12) MCP access: cloud-vault-mcp is mesh-only (wg_only, no bearer door); every
#     other manifest MCP is token-public (bearer_auth)
vmcp=$(jq -c '.mcp_routes[].endpoints[] | select(.base_path=="/cloud-vault-mcp") | {w:(.wg_only==true), b:(.bearer_auth==true)}' "$CADDY")
[ "$vmcp" = '{"w":true,"b":false}' ] && ok "cloud-vault-mcp is wg_only, no bearer (mesh-only)" || bad "cloud-vault-mcp is not mesh-only: $vmcp"
nobearer=$(jq -r --slurpfile m "$MCPM" '($m[0].mcps | map(select(.auth=="token").base_path)) as $t | .mcp_routes[].endpoints[] | select(.base_path as $b | $t | index($b)) | select(.bearer_auth != true) | .base_path' "$CADDY")
[ -z "$nobearer" ] && ok "every other MCP is token-public (bearer_auth)" || bad "token MCPs without bearer_auth: $nobearer"
if [ -f "$EDGE" ] && grep -q '/cloud-vault-mcp' "$EDGE"; then bad "cloud-vault-mcp present in the public-edge allowlist"; fi

# 13) every manifest MCP ALSO has a private mesh address c3-{container}.app
#     (url_scheme.mcp_private, served as a private_mesh_routes site, no token);
#     the public mcp.diegonmarcos.com paths stay token-gated (9, 12) and vault
#     stays mesh-only (12).
nopriv=$(jq -r --slurpfile m "$MCPM" --arg c3 "$C3_RE" '. as $r | $m[0].mcps[].base_path as $b
  | ([$r.url_scheme.mcp_private[]? | select(.base_path==$b)][0]) as $p
  | select($p == null or ($p.private | test($c3) | not)
           or ([$r.private_mesh_routes[] | select(.service==$p.private)] | length) == 0) | $b' "$CADDY")
[ -z "$nopriv" ] && ok "every MCP has a private mesh address c3-<container>.app" || bad "MCPs without a private mesh address: $nopriv"

exit $fail
