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
  # The edge rate-limits one source at 100 req/min (zone global): pace ourselves, and
  # retry a 429 (rate-limited, says nothing about the gate) instead of reporting it.
  local try
  for try in 1 2 3 4; do
    sleep "${PROBE_PACE:-0.9}"
    out=$(curl -sS -D /tmp/.eap.$$ -o /dev/null -m 12 -w '%{http_code}|%{redirect_url}' "${extra[@]}" -H 'Accept: application/json' "https://$host$path" 2>/dev/null) || out="000|"
    code="${out%%|*}"; loc="${out#*|}"
    # A sandboxed network's egress gateway answers *.app / unknown SNIs itself
    # (x-deny-reason: resolve_*), or reaches the REAL public domain of that name
    # (vaultwarden.app is one): neither says anything about OUR edge. Flag it.
    if grep -qi '^x-deny-reason:' /tmp/.eap.$$ 2>/dev/null; then rm -f /tmp/.eap.$$; printf 'skip\t%s\t%s%s\t%s\t(egress gateway answered, not our edge)\n' "$kind" "$host" "$path" "$code"; return; fi
    rm -f /tmp/.eap.$$
    [ "$code" = 429 ] || break
    sleep 30
  done
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
# ONLY meaningful from a network with direct egress to the edge IP (a CI runner, a mesh
# host). Behind a sandboxing egress gateway these come back as "skip" or hit the real
# public domain of the same name (vaultwarden.app exists) -- do not read them there.
# Only the c3-*.app names are unambiguous there (no such public domain).
APPS="$(printf '%s\n' c3-infra-api.mesh.diegonmarcos.com c3-gitea.mesh.diegonmarcos.com c3-authelia.mesh.diegonmarcos.com gitea.mesh.diegonmarcos.com cloud.gitea.mesh.diegonmarcos.com s3-photos.mesh.diegonmarcos.com | awk '{print "private\t"$1"\t/\trefused"}')"

RES="$(printf '%s\n%s\n' "$LIST" "$APPS" | awk -F'\t' 'NF>=3' | \
  xargs -P 2 -d '\n' -I{} bash -c 'IFS=$'"'"'\t'"'"' read -r k h p e <<<"$1"; probe_one "$k" "$h" "$p" "$e"' _ {} | sort)"
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
# ── multi-SSO (edge_auth.multi_sso, #1066) ── only probed once the flag is ON in the derived policy.
# Anonymous browser on BOTH sign-in hosts: the three-button chooser; the broker start routes must send
# the browser to the provider (never 2xx); a non-allowlisted login is refused by the broker itself (its
# allowlist is guarded in cloud-u-containers infra-sec_caddy/src/test/test-multi-sso.sh).
MS_JSON="$ROOT/1_cloud-configs/dist/build-caddy.json"
if [ "$(jq -r '.edge_auth.multi_sso.enabled // false' "$MS_JSON")" = true ]; then
  for h in $(jq -r '.edge_auth.multi_sso.hosts[]' "$MS_JSON"); do
    sleep "${PROBE_PACE:-0.9}"
    body=$(curl -sS -m 12 -H 'Accept: text/html' "https://$h/") || body=""
    if printf '%s' "$body" | grep -q 'Sign in with Authelia' && printf '%s' "$body" | grep -q 'Sign in with Google' && printf '%s' "$body" | grep -q 'Sign in with GitHub'; then
      echo "ok	sso-chooser	$h/	200	-"
    else echo "FAIL	sso-chooser	$h/	-	- (anonymous browser did not get the three-button page)"; fails=$((fails+1)); fi
    for pv in google:accounts.google.com github:github.com; do
      sleep "${PROBE_PACE:-0.9}"
      loc=$(curl -sS -o /dev/null -m 12 -w '%{http_code} %{redirect_url}' "https://$h/oauth2/${pv%%:*}/start?rd=/") || loc="000 "
      if [[ "$loc" =~ ^30[1278]\ https://${pv#*:}/ ]]; then echo "ok	sso-start	$h/oauth2/${pv%%:*}/start	${loc%% *}	-"
      else echo "FAIL	sso-start	$h/oauth2/${pv%%:*}/start	$loc	- (expected a redirect to ${pv#*:})"; fails=$((fails+1)); fi
    done
  done
  sleep "${PROBE_PACE:-0.9}"
  code=$(curl -sS -o /dev/null -m 12 -w '%{http_code}' -H 'Cookie: _diego_sso=forged' "https://mcp.$BASE/") || code=000
  case "$code" in 401|403) echo "ok	sso-forged-cookie	mcp.$BASE/	$code	-" ;; *) echo "FAIL	sso-forged-cookie	mcp.$BASE/	$code	- (a forged broker cookie must be refused)"; fails=$((fails+1)) ;; esac
else
  echo "info	sso	multi_sso OFF in the derived policy: sign-in probes not run	-	-"
fi
echo "-- $total probes, $fails FAIL"
[ "$fails" -eq 0 ]
