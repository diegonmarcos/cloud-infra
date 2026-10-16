#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/edge-auth-probe.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# edge-auth-probe.sh -- POST-DEPLOY: probe every public route ANONYMOUSLY and fail
# on any 2xx, or any 3xx that is not a redirect to auth., on a route that is not
# declared public-open. (Live counterpart of edge-auth-gate.test.sh; hits the
# network, so it is NOT a CI tester -- run it after `ship`.)
#
#   edge-auth-probe.sh                 probe everything in the route list
#   FLEET_BEARER=<jwt> edge-auth-probe.sh   also assert the bearer is accepted
#                                      (c3-infra-mcp initialize must not be 401/403)
#
# Route list: `url-exposure.py probe-list` -> kind<TAB>host<TAB>path<TAB>expect
#   protected  tier b route: anonymous must get 401 / 403 / 302->auth.   (2xx = FAIL)
#   private    tier a host:  anonymous must get 403 / 401 / 302->auth. / no TLS answer
#   open       tier c:       reported only (anonymous is allowed by the list)
# Also probes the *.app mesh names through the public edge IP (SNI passthrough):
# they must be refused, never proxied.
set -uo pipefail
ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
BASE="${PROBE_DOMAIN:-diegonmarcos.com}"
AUTH_RE="^https://auth\.${BASE//./\\.}(/|\$)"
EDGE_IP="${EDGE_IP:-$(getent hosts "$BASE" | awk '{print $1; exit}')}"
LIST="$(python3 -I "$ROOT/1_cloud-configs/src/derive/url-exposure.py" probe-list)" || { echo "FAIL: cannot build the route list"; exit 2; }

probe_one() {  # kind host path expect -> prints "STATUS|redirect|verdict"
  local kind="$1" host="$2" path="$3" extra=() out code loc verdict
  case "$host" in *.app|*.db) extra=(--noproxy "*" --resolve "$host:443:$EDGE_IP" -k) ;; esac
  out=$(curl -sS -o /dev/null -m 12 -w '%{http_code}|%{redirect_url}' "${extra[@]}" -H 'Accept: application/json' "https://$host$path" 2>/dev/null) || out="000|"
  code="${out%%|*}"; loc="${out#*|}"
  verdict=FAIL
  case "$kind" in
    open) verdict=info ;;
    protected|private)
      case "$code" in
        401|403) verdict=ok ;;
        000)     [ "$kind" = private ] && verdict=ok ;;        # nothing answered: not served
        301|302|303|307|308) [[ "$loc" =~ $AUTH_RE ]] && verdict=ok ;;
      esac ;;
  esac
  printf '%s\t%s\t%s%s\t%s\t%s\n' "$verdict" "$kind" "$host" "$path" "$code" "${loc:--}"
}
export -f probe_one; export AUTH_RE EDGE_IP

# *.app / *.db names must never be served through the edge: probe a representative set.
APPS="$(printf '%s\n' c3-infra-api.app c3-gitea.app gitea.app vaultwarden.app cloud.gitea.app s3-photos.app | awk '{print "private\t"$1"\t/\trefused"}')"

RES="$(printf '%s\n%s\n' "$LIST" "$APPS" | awk -F'\t' 'NF>=3' | \
  xargs -P 8 -d '\n' -I{} bash -c 'IFS=$'"'"'\t'"'"' read -r k h p e <<<"$1"; probe_one "$k" "$h" "$p" "$e"' _ {} | sort)"
echo "$RES"
fails=$(printf '%s\n' "$RES" | awk -F'\t' '$1=="FAIL"' | wc -l)
total=$(printf '%s\n' "$RES" | wc -l)

if [ -n "${FLEET_BEARER:-}" ]; then
  code=$(curl -sS -o /dev/null -m 15 -w '%{http_code}' -H "Authorization: Bearer $FLEET_BEARER" -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"edge-auth-probe","version":"1"}}}' \
    "https://mcp.$BASE/c3-infra-mcp/mcp") || code=000
  case "$code" in 200|202) echo "ok	bearer	mcp.$BASE/c3-infra-mcp/mcp	$code	-" ;; *) echo "FAIL	bearer	mcp.$BASE/c3-infra-mcp/mcp	$code	- (fleet bearer rejected)"; fails=$((fails+1)) ;; esac
fi
echo "-- $total probes, $fails FAIL"
[ "$fails" -eq 0 ]
