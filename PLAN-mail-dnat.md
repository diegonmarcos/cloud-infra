# PLAN: Replace Caddy L4 mail passthrough with kernel DNAT

## Problem

Caddy L4 acts as a TCP middleman for mail protocols (IMAP/SMTP/JMAP).
Two TCP sessions (client→Caddy, Caddy→oci-mail) instead of one.
Caddy should only handle HTTP. Mail is not HTTP.

## Goal

Mail ports on gcp-proxy use **iptables DNAT** to forward packets directly
to oci-mail (`10.0.0.3`) over wg0. One TCP session end-to-end.
Caddy is removed from the mail path entirely.

```
BEFORE:  Client → gcp-proxy:993 → Caddy L4 (2 sockets) → wg0 → oci-mail:993
AFTER:   Client → gcp-proxy:993 → kernel DNAT → wg0 → oci-mail:993 (1 session)
```

## Ports to migrate

| Port | Protocol | Current (Caddy L4) | Target (DNAT) |
|------|----------|--------------------|---------------|
| 993  | IMAPS    | Caddy → 10.0.0.3:993  | DNAT → 10.0.0.3:993  |
| 465  | SMTPS    | Caddy → 10.0.0.3:465  | DNAT → 10.0.0.3:465  |
| 587  | Submission | Caddy → 10.0.0.3:587 | DNAT → 10.0.0.3:587  |
| 2993 | IMAPS (stalwart)   | Caddy → 10.0.0.3:2993 | DNAT → 10.0.0.3:2993 |
| 2465 | SMTPS (stalwart)   | Caddy → 10.0.0.3:2465 | DNAT → 10.0.0.3:2465 |
| 2587 | Submission (stalwart) | Caddy → 10.0.0.3:2587 | DNAT → 10.0.0.3:2587 |
| 2443 | JMAP/HTTPS (stalwart) | Caddy → 10.0.0.3:2443 | DNAT → 10.0.0.3:2443 |

## Affected files (all SOURCE, all declarative)

### 1. firewall.nix — Add DNAT rules
**File**: `cloud/b_infra/home-manager/nixhm-sudo-gcp-proxy/src/modules/network/firewall.nix`

Add a new PHASE between FORWARD and NAT:

```bash
# PHASE 3: NAT TABLE — DNAT for mail ports (TCP passthrough to oci-mail)
# One end-to-end TCP session — kernel rewrites dest IP, no userland proxy.
```

For each mail port:
```bash
iptables -t nat -A PREROUTING -i eth0 -p tcp --dport PORT -j DNAT --to-destination 10.0.0.3:PORT
```

Also need FORWARD rules to allow DNAT'd traffic:
```bash
iptables -A FORWARD -p tcp --dport PORT -d 10.0.0.3 -j ACCEPT
```

DNAT data should come from cloud-data (not hardcoded) — derive from `l4_routes[]` or a new `dnat_routes[]` key.

### 2. Caddy L4 — Remove mail routes
**File**: `cloud/a_solutions/bb-sec_caddy/src/flake.nix`

Remove all mail ports from `l4_routes[]` consumption. The `mkL4Section` should only contain non-mail L4 routes (if any remain — currently all L4 routes are mail).

### 3. build-caddy.json / derive — Remove l4_routes for mail
**File**: `cloud-data/1_workflows/src/scripts/cloud-data-config-derive.ts`

Either:
- Remove l4_routes entirely from build-caddy.json (if no non-mail L4 routes exist)
- OR split into `l4_routes` (stays in Caddy) and `dnat_routes` (goes to firewall.nix)

### 4. cloud-data-home-manager.json — Add DNAT config
**File**: `cloud-data/1_workflows/src/scripts/cloud-data-config-derive.ts`

Add `dnat_routes[]` to the home-manager derive output so firewall.nix can consume it:
```json
{
  "vms": {
    "gcp-proxy": {
      "dnat_routes": [
        { "port": 993, "dest": "10.0.0.3", "proto": "tcp", "desc": "IMAPS → oci-mail" },
        ...
      ]
    }
  }
}
```

### 5. gcp-proxy public_ports — Keep as-is
The ports (993, 465, etc.) still need to be open in INPUT. They just get DNAT'd instead of reaching Caddy.

### 6. caddy build.json — Remove L4 port declarations from stalwart/maddy
**File**: `cloud/a_solutions/aa-sui_tools-stalwart/build.json` → remove `proxy.primary.l4_ports`
**File**: `cloud/a_solutions/aa-sui_tools-maddy/build.json` → check for l4 declarations

Move these to a new `dnat` key or derive them in the pipeline.

## Execution order

1. Add `dnat_routes` to cloud-data derive → cloud-data-home-manager.json
2. Update firewall.nix to consume `dnat_routes` and add DNAT + FORWARD rules
3. Remove `l4_routes` from build-caddy.json derive (or filter out mail ports)
4. Remove L4 section from caddy flake.nix (if no routes remain)
5. Deploy home-manager to gcp-proxy (applies firewall with DNAT)
6. Deploy caddy to gcp-proxy (removes L4 listener)
7. Test: `openssl s_client -connect mail.diegonmarcos.com:993` should still work
8. Test: JMAP at `diegonmarcos.com:2443` should still work via DNAT

## Rollback

If DNAT breaks mail: revert home-manager + caddy deploys. L4 routes still in Caddy.

## Notes

- DNAT requires `ip_forward=1` (already enabled for WG)
- DNAT'd packets traverse FORWARD chain — need explicit ACCEPT rules
- MASQUERADE on wg0 already exists — return traffic routes correctly
- oci-mail firewall accepts all wg0 traffic — no changes needed there
- Caddy L4 plugin (`caddy-l4`) can be kept in the image for future non-mail use
