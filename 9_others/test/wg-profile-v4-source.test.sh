#!/usr/bin/env bash
# Guards the phone WireGuard profiles against #522: the IPv4 half of a tunnel
# that handshakes fine but carries nothing.
#
# Android installs VPN routes with no preferred source, so the kernel sources
# EVERY IPv4 packet on the tun from its FIRST IPv4 Address. The profiles hold
# two IPv4 identities (e.g. wg0 10.0.0.9, wg-public 10.1.0.9) on one tun, and each
# hub only accepts its own (cryptokey routing: anything else is dropped as
# "unallowed src IP" and counted in the hub's rx_frame_errors — 87873 of them
# on oci-analytics' wg-public, 0 on wg0, measured 2026-09-24). With 10.0.0.9
# first, wg-v6-split reached fd0c:1d01::1 5/5 and 10.1.0.1 0/5, and wg-v6-full
# sent all of 0.0.0.0/0 to oci-analytics as 10.0.0.9: a total v4 outage.
# IPv6 was never affected, since it picks its source by longest prefix.
#
# The property: in every profile that has a v4 CARRIER, the first IPv4 Address
# is the phone's address in the carrier's mesh, as the mesh declaration says.
# The carrier is the peer that owns 0.0.0.0/0, otherwise the one peer with an
# IPv6-literal endpoint (the only hub reachable on a v6-only uplink). A split
# profile with neither has no single right answer and is reported, not
# asserted.
#
# Nothing below is a literal: the profiles are the published, vault-derived
# artifact and the meshes come from the consolidated declaration. Both paths
# can be overridden for the mutation test. A missing input is a FAILURE (#368).
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROFILES="${WG_PROFILES:-$ROOT/1_cloud-configs/src/inputs/superapp-wireguard-profiles.json}"
TOPOLOGY="${WG_TOPOLOGY:-$ROOT/1_cloud-configs/dist/_cloud-data-consolidated.json}"

for f in "$PROFILES" "$TOPOLOGY"; do
    [ -f "$f" ] || { echo "::error::$f not found — this guard is unrun, not passing"; exit 1; }
done

exec python3 - "$PROFILES" "$TOPOLOGY" <<'PY'
import ipaddress, json, re, sys

# #573: profiles are published PER PEER (profiles.<peer>.<profile>); every phone is asserted.
profiles = {f"{peer}/{pid}": prof for peer, profs in json.load(open(sys.argv[1]))["profiles"].items()
            for pid, prof in profs.items()}
native = json.load(open(sys.argv[2]))["native"]
meshes = {"wg0": native.get("wireguard") or {}, "wg-public": native.get("wireguard_public") or {}}

def hub_mesh(pubkey):
    for mesh, m in meshes.items():
        if any(p.get("role") == "hub" and p.get("wg_public_key") == pubkey for p in m.get("peers", [])):
            return mesh
    return None

def parse(text):
    iface, peers, cur = {}, [], None
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if line == "[Peer]":
            cur = {}; peers.append(cur)
        elif "=" in line:
            k, v = (s.strip() for s in line.split("=", 1))
            (cur if cur is not None else iface)[k] = v
    return iface, peers

asserted = failed = 0
for pid, prof in profiles.items():
    iface, peers = parse(prof["config_text"])
    v4 = [str(ipaddress.ip_interface(a.strip()).ip) for a in iface.get("Address", "").split(",")
          if a.strip() and ipaddress.ip_interface(a.strip()).version == 4]
    allowed = lambda p: {a.strip() for a in p.get("AllowedIPs", "").split(",")}
    carrier = [p for p in peers if "0.0.0.0/0" in allowed(p)] or \
              [p for p in peers if p.get("Endpoint", "").startswith("[")]
    if len(carrier) != 1:
        print(f"  n/a   {pid}: no single v4 carrier (split over v4 endpoints)")
        continue
    mesh = hub_mesh(carrier[0].get("PublicKey"))
    if mesh is None:
        print(f"FAIL  {pid}: carrier {carrier[0].get('PublicKey')} is no declared mesh hub"); failed += 1; continue
    mine = [c["wg_ip"] for c in meshes[mesh].get("clients", {}).values() if c.get("wg_ip") in v4]
    if len(mine) != 1:
        print(f"FAIL  {pid}: expected exactly one {mesh} client address among {v4}, found {mine}"); failed += 1; continue
    asserted += 1
    if not v4 or v4[0] != mine[0]:
        print(f"FAIL  {pid}: first IPv4 Address is {v4[0] if v4 else None}, but the v4 carrier is the {mesh} hub, "
              f"which only accepts {mine[0]} — every v4 packet would be dropped as 'unallowed src IP'")
        failed += 1
    else:
        print(f"  ok    {pid}: v4 source {v4[0]} is the {mesh} identity the carrier accepts")

if asserted == 0:
    print("FAIL  no profile was asserted — a guard that checked nothing is not green"); sys.exit(1)
print(f"--- {asserted} asserted, {failed} failed")
sys.exit(1 if failed else 0)
PY
