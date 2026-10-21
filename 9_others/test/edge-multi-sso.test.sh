#!/usr/bin/env bash
# edge-multi-sso.test.sh -- the multi-SSO flag (cloud-u-containers infra-sec_caddy/build.json
# caddy_config.edge_auth.multi_sso, #1066) and the rendered edge agree, in BOTH directions.
#
#   flag false: neither committed Caddyfile carries any sign-in addition (@ea_broker, _diego_sso,
#               account.diegonmarcos.com, /oauth2/) -- the fleet serves exactly what it did before.
#   flag true : every gate snippet (3 per Caddyfile) carries the broker branch, the hub auth site answers
#               every declared host, the edge terminates them, and Bearer / Authelia branches are present.
# Hub and edge must also carry the identical multi_sso block (one declaration, two renders).
# Static: reads the committed build-caddy*.json and rendered Caddyfiles; no network.
set -euo pipefail
ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
HUB_J="$ROOT/1_cloud-configs/dist/build-caddy.json"; EDGE_J="$ROOT/1_cloud-configs/dist/build-caddy-edge.json"
HUB_C="$ROOT/a_solutions/infra-sec_caddy/dist/configs/Caddyfile"; EDGE_C="$ROOT/a_solutions/infra-sec_caddy-public/dist/configs/Caddyfile"
for f in "$HUB_J" "$EDGE_J" "$HUB_C" "$EDGE_C"; do [ -f "$f" ] || { echo "FAIL: missing ${f#$ROOT/} (check out cloud-u-containers into a_solutions)"; exit 1; }; done
fail=0; bad(){ echo "FAIL: $*"; fail=1; }
hub_ms="$(jq -c '.edge_auth.multi_sso // {enabled:false}' "$HUB_J")"; edge_ms="$(jq -c '.edge_auth.multi_sso // {enabled:false}' "$EDGE_J")"
[ "$hub_ms" = "$edge_ms" ] || bad "multi_sso differs between build-caddy.json and build-caddy-edge.json"
on="$(echo "$hub_ms" | jq -r '.enabled // false')"
count(){ grep -c -E -- "$1" "$2" || true; }
if [ "$on" = false ]; then
  for c in "$HUB_C" "$EDGE_C"; do
    for pat in '@ea_broker' '_diego_sso' '(^|[^-A-Za-z0-9])account\.diegonmarcos\.com' '/oauth2/' 'sso-chooser' 'Cf-Access-Jwt-Assertion' '@ea_cfaccess'; do
      [ "$(count "$pat" "$c")" = 0 ] || bad "multi_sso is OFF but ${c#$ROOT/} still carries '$pat'"
    done
  done
  [ "$fail" = 0 ] && echo "ok: multi_sso OFF -> no sign-in addition in either Caddyfile"
else
  for c in "$HUB_C" "$EDGE_C"; do
    [ "$(count 'forward_auth @ea_broker' "$c")" = 3 ] || bad "${c#$ROOT/}: broker branch missing from a gate snippet"
    [ "$(count 'forward_auth @ea_bearer' "$c")" = 3 ] || bad "${c#$ROOT/}: Bearer branch changed"
    [ "$(count 'forward_auth @ea_session' "$c")" = 3 ] || bad "${c#$ROOT/}: Authelia branch changed"
  done
  for h in $(echo "$hub_ms" | jq -r '.hosts[]'); do
    grep -q -E -- "(^|[^-A-Za-z0-9])${h//./\\.}" "$HUB_C" || bad "hub Caddyfile does not serve $h"
    grep -q -E -- "sni .*(^| )${h//./\\.}" "$EDGE_C" || bad "edge Caddyfile does not terminate $h"
  done
  grep -q 'sso-chooser' "$HUB_C" || bad "chooser route missing from the hub"
  if [ "$(echo "$hub_ms" | jq -r '.cloudflare_access.enabled // false')" = true ]; then
    for c in "$HUB_C" "$EDGE_C"; do
      [ "$(count 'forward_auth @ea_cfaccess' "$c")" = 3 ] || bad "${c#$ROOT/}: Cloudflare Access branch missing from a gate snippet"
      [ "$(count '/cf-auth' "$c")" = 3 ] || bad "${c#$ROOT/}: Cloudflare Access branch must call the broker cf-auth"
    done
  else
    for c in "$HUB_C" "$EDGE_C"; do [ "$(count '@ea_cfaccess' "$c")" = 0 ] || bad "cloudflare_access is off but ${c#$ROOT/} carries its branch"; done
  fi
  [ "$(echo "$hub_ms" | jq -r '.allowed_emails // empty')" = "" ] || bad "allowlist must live ONLY in the broker build.json"
  [ "$fail" = 0 ] && echo "ok: multi_sso ON -> broker branch, hosts and routes rendered in both Caddyfiles"
fi
exit "$fail"
