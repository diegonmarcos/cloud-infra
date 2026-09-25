#!/usr/bin/env bash
# Guards the ONE user declaration behind the SuperApp's Profile (#573):
# User (1) -> identities (N, exactly ONE primary) -> peers (N, exactly ONE
# primary, each a client on at least one mesh) -> auth_providers (non-empty),
# and the published per-peer WireGuard profiles agree with it: every peer that
# declares vault_wg_dir has profiles published, every published peer is
# declared, and each published profile's Address line carries that peer's own
# mesh addresses (so a profile can never be filed under the wrong phone).
#
# Nothing below is a literal: the users file, the profiles and the meshes are
# the declared artifacts, each overridable for the mutation test. A missing
# input is a FAILURE (#368).
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
USERS="${SA_USERS:-$ROOT/1_cloud-configs/src/inputs/superapp-users.json}"
PROFILES="${WG_PROFILES:-$ROOT/1_cloud-configs/src/inputs/superapp-wireguard-profiles.json}"
TOPOLOGY="${WG_TOPOLOGY:-$ROOT/1_cloud-configs/dist/_cloud-data-consolidated.json}"

for f in "$USERS" "$PROFILES" "$TOPOLOGY"; do
    [ -f "$f" ] || { echo "::error::$f not found — this guard is unrun, not passing"; exit 1; }
done

exec python3 - "$USERS" "$PROFILES" "$TOPOLOGY" <<'PY'
import ipaddress, json, re, sys

users = json.load(open(sys.argv[1]))["users"]
profiles = json.load(open(sys.argv[2]))["profiles"]
native = json.load(open(sys.argv[3]))["native"]
wg0 = (native.get("wireguard") or {}).get("clients", {})
wgp = (native.get("wireguard_public") or {}).get("clients", {})

failed = asserted = 0
def fail(msg):
    global failed; failed += 1; print("FAIL  " + msg)
def ok(msg):
    global asserted; asserted += 1; print("  ok    " + msg)

def addresses(text):
    for line in text.splitlines():
        m = re.match(r"\s*Address\s*=\s*(.*)", line.split("#", 1)[0])
        if m:
            return {str(ipaddress.ip_interface(a.strip()).ip) for a in m.group(1).split(",") if a.strip()}
    return set()

declared_peers = set()
for slug, u in users.items():
    ids = u.get("identities") or []
    prim = [i.get("email") for i in ids if i.get("primary") is True]
    (ok if len(prim) == 1 else fail)(f"{slug}: {len(ids)} identities, primary = {prim}")
    emails = [i.get("email", "") for i in ids]
    (ok if all("@" in e for e in emails) and len(set(emails)) == len(emails) else fail)(f"{slug}: identities are distinct addresses")
    peers = u.get("peers") or {}
    pprim = [p for p, e in peers.items() if e.get("primary") is True]
    (ok if len(pprim) == 1 else fail)(f"{slug}: {len(peers)} peers, primary = {pprim}")
    (ok if u.get("auth_providers") else fail)(f"{slug}: auth_providers = {u.get('auth_providers')}")
    for pid, p in peers.items():
        declared_peers.add(pid)
        c = p.get("wg_client")
        row0, rowp = wg0.get(c), wgp.get(c)
        if not (row0 or rowp):
            fail(f"{slug}/{pid}: wg_client '{c}' is a client on neither mesh"); continue
        ok(f"{slug}/{pid}: wg_client '{c}' → wg0 {row0 and row0.get('wg_ip')} / wg-public {rowp and rowp.get('wg_ip')}")
        mine = {v for r in (row0, rowp) if r for v in (r.get("wg_ip"), r.get("wg_ipv6")) if v}
        if p.get("vault_wg_dir"):
            pub = profiles.get(pid)
            if not pub:
                fail(f"{slug}/{pid}: declares vault_wg_dir but no profiles are published — run regen-superapp-wireguard-profiles.js"); continue
            for prof_id, prof in pub.items():
                addrs = addresses(prof["config_text"])
                if addrs and addrs <= mine:
                    ok(f"{slug}/{pid}/{prof_id}: every Address is this peer's ({sorted(addrs)})")
                else:
                    fail(f"{slug}/{pid}/{prof_id}: Address line {sorted(addrs)} is not this peer's identity {sorted(mine)}")
for pid in profiles:
    (ok if pid in declared_peers else fail)(f"published peer '{pid}' is declared in superapp-users.json")

if asserted == 0:
    print("FAIL  nothing was asserted — a guard that checked nothing is not green"); sys.exit(1)
print(f"--- {asserted} asserted, {failed} failed")
sys.exit(1 if failed else 0)
PY
