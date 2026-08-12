#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ OCI VM bootstrap — network half (oci-analytics)                  ║
# ║ Source: c_vps/vps_oci/src/bootstrap.sh                           ║
# ╚══════════════════════════════════════════════════════════════════╝
#
# WHY THIS EXISTS
# ───────────────
# GCP VMs get c_vps/vps_gcloud/src/bootstrap.sh wired through
# main.tf metadata.startup-script. The OCI instances have `metadata = {}`
# (main.tf:207) and `lifecycle.ignore_changes = [… metadata …]` (main.tf:225),
# so they have NO bootstrap at all and adding one would not reach a running
# instance anyway. Everything below is therefore applied by hand:
#
#   sudo bash bootstrap.sh
#
# WHAT IT DOES — it is the imperative twin of two home-manager modules that are
# committed and imported but have never successfully deployed:
#   b_infra/_shared/vm-pilot/src/modules/network/ipv6-guest.nix
#   b_infra/_shared/vm-pilot/src/modules/network/nat64-tayga.nix
# Same addresses, same prefix, same unit name, same file paths — so when the
# ship finally lands it overwrites these with identical content and converges
# rather than conflicting.
#
# ponytail: stopgap by construction. Delete it once `Ship → home-manager`
# deploys oci-analytics cleanly; it buys IPv6 connectivity in the meantime.
#
# THE BUG IT FIXES
# ────────────────
# Unbound on 10.1.0.1 does DNS64: it answers AAAA for IPv4-only hosts with a
# synthesized address in 2603:c026:c104:8f00:ff9b::/96.
#     dig @10.1.0.1 AAAA github.com -> 2603:c026:c104:8f00:ff9b:0:8c52:7103
# Nothing on this host translates that prefix — no tayga, no ff9b route — so a
# phone on an IPv6-only WiFi resolves a name, prefers the synthetic AAAA over
# the real A, sends into ::/0, and the packets die here. WireGuard handshakes
# fine and there is still no internet. DNS64 without NAT64 is worse than
# neither. This script supplies the missing NAT64 half.

set -euo pipefail

# Must match ANALYTICS_IPV6 in ipv6-guest.nix and hub.host_v6 in
# wireguard-public-endpoints.json, or the phone dials an address we do not hold.
ANALYTICS_IPV6="2603:c026:c104:8f00:0:c704:63b:6eee"

# Must match NAT64_PREFIX in nat64-tayga.nix AND dns64-prefix in
# a_solutions/infra-net_unbound-dns64/src/flake.nix. If these three ever
# disagree, Unbound synthesizes into a prefix nothing translates — which is
# precisely the outage above.
NAT64_PREFIX="2603:c026:c104:8f00:ff9b::/96"
NAT64_IPV6_ADDR="2603:c026:c104:8f00::2"   # inside the /64, OUTSIDE the /96
XLATE_POOL="192.168.255.0/24"
TUN_DEVICE="nat64"
TUN_IPV4="192.168.255.1"

# nat64 tun MTU. NOT the default 1500, and getting this wrong produces the most
# deceptive failure mode in the whole stack: TCP connects, small replies arrive,
# and every large response vanishes — which looks exactly like "no internet"
# while every check you would think to run reports healthy.
#
# The clients that use NAT64 arrive over wg-public, whose MTU is 1380.
# Translating IPv4 -> IPv6 GROWS the header by 20 bytes (20 -> 40), so a 1380
# byte IPv4 reply becomes a 1400 byte IPv6 packet that cannot leave a 1380
# interface. Working backwards: 1380 - 20 = 1360. With the tun at 1360, tayga
# tells IPv4 senders "Frag Needed, MTU 1360" and everything it emits fits
# inside wg-public.
#
# Keep in sync if wg-public's MTU ever changes (currently set by the wireguard
# module); the invariant is NAT64_MTU = wg-public MTU - 20.
NAT64_MTU="1360"

log() { echo "[oci-bootstrap] $*"; }

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

# Interface resolved at runtime, never hardcoded: a wrong name yields a netplan
# file that applies cleanly and does absolutely nothing.
IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
IFACE=${IFACE:-ens3}
log "primary interface: $IFACE"

# ── 1. Persist the OCI-assigned IPv6 ────────────────────────────────────────
# Terraform (oci_core_ipv6.analytics_v6) allocates this in the OCI control
# plane, but the guest OS never configures it, so nothing here ever listens on
# it. It is currently up only because it was added by hand and dies on reboot.
#
# /128 not /64: OCI routes the address to the VNIC as a host route. Claiming the
# whole /64 would make the guest treat every subnet neighbour as link-local and
# blackhole them.
#
# A drop-in, never an edit of 50-cloud-init.yaml — cloud-init rewrites that file
# on boot and the change would silently vanish. Higher numbers merge over lower.
#
# The address is asserted statically but the GATEWAY deliberately is not: OCI
# publishes no static IPv6 gateway and the virtual router's link-local varies per
# subnet. Guessing it would install a bogus default route on the wg-public hub —
# the machine you would need in order to undo it. accept-ra takes the route from
# the authority that owns it.
log "1/4 netplan drop-in for $ANALYTICS_IPV6"
cat > /etc/netplan/99-ipv6.yaml <<EOF
# Managed by c_vps/vps_oci/src/bootstrap.sh — mirrors ipv6-guest.nix
network:
  version: 2
  ethernets:
    $IFACE:
      dhcp6: true
      accept-ra: true
      addresses:
        - $ANALYTICS_IPV6/128
EOF
chmod 600 /etc/netplan/99-ipv6.yaml   # netplan ignores world-readable configs
netplan apply || log "WARN: netplan apply reported an error"

# ── 2. Forwarding ───────────────────────────────────────────────────────────
# NAT64 is a routing function; without v6 forwarding the tun device receives
# translated packets and drops them.
log "2/4 enable forwarding"
cat > /etc/sysctl.d/99-nat64.conf <<'EOF'
net.ipv6.conf.all.forwarding = 1
net.ipv4.ip_forward = 1
EOF
sysctl -q -p /etc/sysctl.d/99-nat64.conf

# ── 3. Tayga ────────────────────────────────────────────────────────────────
log "3/4 install + configure tayga"
if ! command -v tayga >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tayga
fi
TAYGA_BIN=$(command -v tayga)
mkdir -p /var/db/tayga

cat > /etc/tayga.conf <<EOF
# Managed by c_vps/vps_oci/src/bootstrap.sh — mirrors nat64-tayga.nix
tun-device    $TUN_DEVICE
ipv4-addr     $TUN_IPV4
prefix        $NAT64_PREFIX
ipv6-addr     $NAT64_IPV6_ADDR
dynamic-pool  $XLATE_POOL
data-dir      /var/db/tayga
EOF
chmod 644 /etc/tayga.conf

# Same unit name and path the nix module uses, so the ship replaces rather than
# duplicates it. Routes and MASQUERADE go in ExecStartPost because the tun
# device does not exist until tayga has started.
cat > /etc/systemd/system/nat64-tayga.service <<EOF
[Unit]
Description=Tayga NAT64 translator (bootstrap)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$TAYGA_BIN -d --config /etc/tayga.conf
ExecStartPost=/sbin/ip link set $TUN_DEVICE mtu $NAT64_MTU
ExecStartPost=/sbin/ip link set $TUN_DEVICE up
ExecStartPost=-/sbin/ip route add $NAT64_PREFIX dev $TUN_DEVICE
ExecStartPost=-/sbin/ip route add $XLATE_POOL dev $TUN_DEVICE
ExecStartPost=/bin/sh -c 'OIF=\$(ip route show default | awk "/default/ {print \\\$5; exit}"); OIF=\${OIF:-$IFACE}; iptables -t nat -C POSTROUTING -s $XLATE_POOL -o "\$OIF" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s $XLATE_POOL -o "\$OIF" -j MASQUERADE'
# FORWARD accepts for the tun. THIS IS NOT OPTIONAL and nat64-tayga.nix omits
# it — the module installs MASQUERADE only. This host runs -P FORWARD DROP with
# per-interface accepts for wg0 and wg-public, so a phone's packet reaches the
# tun (matched by "-i wg-public") and then the TRANSLATED packet leaving the tun
# matches no rule and is dropped. Result: tayga running, routes correct,
# MASQUERADE present, and still zero connectivity. Verified: adding these turned
# a 15s timeout into HTTP 200 through the synthesized address.
ExecStartPost=/bin/sh -c 'for t in iptables ip6tables; do for d in -i -o; do \$t -C FORWARD \$d $TUN_DEVICE -j ACCEPT 2>/dev/null || \$t -A FORWARD \$d $TUN_DEVICE -j ACCEPT; done; done'
Restart=on-failure
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable nat64-tayga.service >/dev/null 2>&1 || true
systemctl restart nat64-tayga.service

# ── 4. Report ───────────────────────────────────────────────────────────────
# Address and route reported separately on purpose: the address is static now,
# so "has an address" proves nothing. Only the RA-supplied default route shows
# the host can answer off-subnet traffic like a handshake from a v6-only WiFi.
sleep 3
log "4/4 result"
V6=$(ip -6 addr show dev "$IFACE" scope global 2>/dev/null | awk '/2603:/ {print $2; exit}')
[ -n "$V6" ] && log "  address OK   $V6" || log "  WARNING: no global IPv6 on $IFACE"

ROUTE=$(ip -6 route show default 2>/dev/null | head -1)
[ -n "$ROUTE" ] && log "  route OK     $ROUTE" || log "  WARNING: no IPv6 default route — off-subnet traffic cannot work"

if ip link show "$TUN_DEVICE" >/dev/null 2>&1; then
  log "  tun OK       $TUN_DEVICE up"
  ip -6 route show "$NAT64_PREFIX" 2>/dev/null | sed 's/^/  route64      /'
else
  log "  WARNING: $TUN_DEVICE missing — check: journalctl -u nat64-tayga -n 40"
fi
log "done. verify from a v6-only client: curl -6 https://github.com"
