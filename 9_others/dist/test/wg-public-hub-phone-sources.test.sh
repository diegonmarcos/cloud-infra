#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/wg-public-hub-phone-sources.test.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Guards the wg-public HUB half of #522: the hub must accept, for the phone's
# key, every IPv4 source address the phone's profiles can send from.
#
# One tun carries the phone's two IPv4 identities (wg0 10.0.0.9, wg-public
# 10.1.0.9) and Android sources every v4 packet from the FIRST Address. The v6
# profiles lead with the wg-public one (wg-profile-v4-source.test.sh), but the
# v4 profiles lead with the wg0 one, so their packets to the wg-public hub
# arrive as 10.0.0.9 — dropped as "unallowed src IP" unless the peer's
# AllowedIPs carry it. The hub renders AllowedIPs from the client's wg_ip plus
# clients.<name>.extra_allowed_ips (declared in the wg-public owner's
# build.json, rendered by vm-pilot network/wireguard.nix).
#
# The property, per profile: every IPv4 Address in it is accepted by the
# wg-public client it belongs to (wg_ip, or an extra_allowed_ips entry), and the
# renderer really emits extra_allowed_ips. Nothing below is a literal: both
# inputs are declared artifacts and can be overridden for the mutation test. A
# missing input is a FAILURE (#368).
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROFILES="${WG_PROFILES:-$ROOT/1_cloud-configs/src/inputs/superapp-wireguard-profiles.json}"
TOPOLOGY="${WG_TOPOLOGY:-$ROOT/1_cloud-configs/dist/_cloud-data-consolidated.json}"
RENDERER="${WG_RENDERER:-$ROOT/b_infra/_shared/vm-pilot/src/modules/network/wireguard.nix}"

for f in "$PROFILES" "$TOPOLOGY" "$RENDERER"; do
    [ -f "$f" ] || { echo "::error::$f not found — this guard is unrun, not passing"; exit 1; }
done

exec python3 - "$PROFILES" "$TOPOLOGY" "$RENDERER" <<'PY'
import ipaddress, json, re, sys

# #573: profiles are published PER PEER (profiles.<peer>.<profile>); every phone is asserted.
profiles = {f"{peer}/{pid}": prof for peer, profs in json.load(open(sys.argv[1]))["profiles"].items()
            for pid, prof in profs.items()}
clients = (json.load(open(sys.argv[2]))["native"].get("wireguard_public") or {}).get("clients", {})
renderer = open(sys.argv[3]).read()

failed = asserted = 0
if "extra_allowed_ips" not in renderer:
    print("FAIL  renderer never reads extra_allowed_ips — the declaration would be silently ignored"); failed += 1

for pid, prof in profiles.items():
    addrs = []
    for line in prof["config_text"].splitlines():
        m = re.match(r"\s*Address\s*=\s*(.*)", line.split("#", 1)[0])
        if m:
            addrs += [ipaddress.ip_interface(a.strip()).ip for a in m.group(1).split(",") if a.strip()]
    v4 = [str(a) for a in addrs if a.version == 4]
    owner = [c for c in clients.values() if c.get("wg_ip") in v4]
    if len(owner) != 1:
        print(f"  n/a   {pid}: {len(owner)} wg-public client identities among {v4}"); continue
    accepted = {owner[0]["wg_ip"], *(ip.split("/")[0] for ip in owner[0].get("extra_allowed_ips", []))}
    asserted += 1
    missing = [a for a in v4 if a not in accepted]
    if missing:
        print(f"FAIL  {pid}: the wg-public hub does not accept {missing} for this key — packets sourced from "
              f"them are dropped as 'unallowed src IP' (accepts {sorted(accepted)})"); failed += 1
    else:
        print(f"  ok    {pid}: hub accepts all of {v4}")

if asserted == 0:
    print("FAIL  no profile was asserted — a guard that checked nothing is not green"); sys.exit(1)
print(f"--- {asserted} asserted, {failed} failed")
sys.exit(1 if failed else 0)
PY
