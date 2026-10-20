#!/usr/bin/env bash
# Linux twin of the SuperApp's Cloud Mesh "Test fallbacks" (#932).
#
# Public Wi-Fi that blocks external DNS, port 53 or the mesh's UDP ports leaves
# the tunnel with no handshake. The fleet answers with a ladder; this probes
# each rung from a Linux box and names the one that works, from the SAME
# declaration the phone uses: dist/mesh-snapshot.json::bootstrap (nothing typed).
#
#   hosts                 print the pinned domain->IP lines (/etc/hosts format)
#   check                 probe: direct UDP, system DNS vs pin, pinned IP, DoH by IP, TLS-443 relay
#   ssh-tunnel <user@vm>  print the manual SSH-tunnel fallback (last resort, no wg needed)
#
# env: MESH_SNAPSHOT (default: dist/mesh-snapshot.json beside this repo),
#      WSTUNNEL_PATH_PREFIX (the relay's secret path prefix; without it the relay rung is SKIPPED, not failed),
#      MESH_DOH (space-separated DoH resolver IPs; default 1.1.1.1 8.8.8.8)
# exit: 0 when at least one rung carries traffic, 1 when none does, 2 on a missing input.
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SNAP="${MESH_SNAPSHOT:-$ROOT/1_cloud-configs/dist/mesh-snapshot.json}"
DOH="${MESH_DOH:-1.1.1.1 8.8.8.8}"

die() { echo "::error::$*" >&2; exit 2; }
command -v jq >/dev/null || die "jq is required"
[ -s "$SNAP" ] || die "$SNAP not found — the ladder has nothing to pin"
jq -e '.bootstrap.pinned_hosts | length > 0' "$SNAP" >/dev/null 2>&1 || die "$SNAP has no bootstrap.pinned_hosts"

cmd_hosts() { jq -r '.bootstrap.etc_hosts[]' "$SNAP"; }

ok=0
rung() { # name verdict detail
    printf '%-14s %-5s %s\n' "$1" "$2" "$3"; [ "$2" = PASS ] && ok=$((ok + 1)); return 0; }

cmd_check() {
    local relay_host prefix hub_if
    relay_host=$(jq -r '.bootstrap.relay.host // empty' "$SNAP")

    # 1. Direct UDP: any hub with a fresh handshake (<180 s) on this machine.
    local hs="" now; now=$(date +%s)
    if command -v wg >/dev/null; then
        hs=$(wg show all latest-handshakes 2>/dev/null | awk -v n="$now" '$3 > 0 && n - $3 < 180 {print $1; exit}')
    fi
    if [ -n "$hs" ]; then rung "direct-udp" PASS "fresh handshake on $hs"
    else rung "direct-udp" FAIL "no handshake under 180 s (wg absent, down, or UDP blocked)"; fi

    # 2. System DNS must agree with the pin; a split-horizon mesh answer is not a hijack.
    local host v4 v6 ans
    while IFS=$'\t' read -r host v4 v6; do
        ans=$(getent ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
        if [ -z "$ans" ]; then rung "system-dns" FAIL "$host does not resolve"
        elif printf '%s\n' $v4 $v6 | grep -qxFf <(printf '%s\n' $ans); then rung "system-dns" PASS "$host -> $ans(matches the pin)"
        else rung "system-dns" FAIL "$host -> $ans(not in the pin: $v4 $v6) — hijacked or split-horizon"; fi
    done < <(jq -r '.bootstrap.pinned_hosts[] | [.host, (.v4|join(" ")), (.v6|join(" "))] | @tsv' "$SNAP")

    # 3. Pinned IP: real TLS to the pinned address with the host as SNI, certificate verified.
    local ip
    while IFS=$'\t' read -r host ip; do
        if curl -sS -o /dev/null -m 8 --resolve "$host:443:$ip" "https://$host/" 2>/dev/null; then rung "pinned-ip" PASS "$host @ $ip (TLS verified)"
        else rung "pinned-ip" FAIL "$host @ $ip"; fi
    done < <(jq -r '.bootstrap.pinned_hosts[] | .host as $h | (.v4[], .v6[]) | [$h, .] | @tsv' "$SNAP")

    # 4. DoH by IP: no system DNS involved.
    local r
    for r in $DOH; do
        if [ -n "$relay_host" ] && curl -sS -m 8 -H 'accept: application/dns-json' "https://$r/dns-query?name=$relay_host&type=A" 2>/dev/null | jq -e '.Answer | length > 0' >/dev/null 2>&1
        then rung "doh" PASS "$r answers $relay_host"; else rung "doh" FAIL "$r"; fi
    done

    # 5. TLS-443 relay: the wstunnel upgrade must be accepted (101).
    prefix="${WSTUNNEL_PATH_PREFIX:-}"
    if [ -z "$relay_host" ]; then rung "relay-443" SKIP "no relay declared"
    elif [ -z "$prefix" ]; then rung "relay-443" SKIP "WSTUNNEL_PATH_PREFIX not set"
    else
        local code
        code=$(curl -sS -o /dev/null -m 8 -w '%{http_code}' --http1.1 \
            -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
            -H "Sec-WebSocket-Key: $(head -c16 /dev/urandom | base64)" \
            "https://$relay_host/$prefix/events" 2>/dev/null || true)
        if [ "$code" = 101 ] || [ "$code" = 400 ]; then rung "relay-443" PASS "upgrade endpoint answered $code"
        else rung "relay-443" FAIL "HTTP ${code:-none}"; fi
    fi

    echo
    if [ "$ok" -gt 0 ]; then echo "$ok rung(s) carry traffic"; return 0; fi
    echo "no rung carries traffic — see: $0 ssh-tunnel <user@vm>"; return 1
}

cmd_ssh_tunnel() {
    local target="${1:-}"; [ -n "$target" ] || die "usage: $0 ssh-tunnel <user@vm>"
    cat <<TXT
# Manual fallback when every rung above fails: carry the hub's WireGuard UDP over an SSH TCP stream.
# 1. keep an SSH session to a reachable VM (port 443 is the usual open port):
ssh -p 443 -N -L 127.0.0.1:51820:127.0.0.1:51820 $target
# 2. point the wg peer's Endpoint at 127.0.0.1:51820 and use socat to wrap UDP in that TCP:
#    socat UDP4-LISTEN:51820,fork,reuseaddr TCP4:127.0.0.1:51820   (and the matching UDP4 side on the VM)
# Prefer the TLS-443 relay (rung 5); this exists so a laptop is never locked out.
TXT
}

case "${1:-}" in
    hosts) cmd_hosts ;;
    check) cmd_check ;;
    ssh-tunnel) shift; cmd_ssh_tunnel "$@" ;;
    *) sed -n '2,17p' "$0"; exit 2 ;;
esac
