# Firewall Sovereign Lockdown — nftables as Single Source of Truth

> **Date**: 2026-03-18
> **Updated**: 2026-03-18
> **Status**: Draft

---

## Checklist

- [ ] Phase 1: Audit & fix Caddy upstreams (public IP → WG IP)
- [ ] Phase 2: Disable Docker iptables on all VMs
- [ ] Phase 3: Deploy nftables declarative firewall (pre-Docker systemd)
- [ ] Phase 4: Lock services to WG-only binds (fix docker-compose ports)
- [ ] Phase 5: Disable rpcbind on all VMs
- [ ] Phase 6: Remove 5432 from public firewall, bind Postgres to WG-only
- [ ] Phase 7: SSH hardening (WG-only option)
- [ ] Phase 8: Verification & regression tests

---

## Problem

Current state has **three competing sources of truth** for network access:
1. **iptables** — our declared rules (home-manager `networking.firewall`)
2. **Docker** — rewrites iptables at runtime, bypasses INPUT chain via FORWARD/nat
3. **Service binds** — containers bind to `0.0.0.0` regardless of intent

Docker's iptables manipulation inserts rules in the `DOCKER` and `DOCKER-USER` chains that can **bypass our INPUT rules entirely** — a container binding `0.0.0.0:5432` with a `ports:` mapping is reachable even if iptables INPUT blocks 5432.

**Goal**: nftables is the one and only firewall. Docker cannot write rules. If nftables doesn't open a port, it is unreachable — period.

---

## Architecture Decision

### Firewall Stack

```
nftables (loaded at boot, Before=docker.service)
  ├── table inet filter
  │   ├── chain input   { policy drop; explicit allowlist }
  │   ├── chain forward { policy drop; explicit WG routing }
  │   └── chain output  { policy accept }
  └── table ip nat
      ├── chain prerouting  { DNAT for Docker ports we explicitly expose }
      └── chain postrouting { MASQUERADE for WG }
```

### Docker — iptables disabled

```json
// /etc/docker/daemon.json
{
  "iptables": false
}
```

With `iptables: false`:
- Docker writes NO iptables/nftables rules
- Container `ports:` mappings still bind the host port (via runc), but traffic is only routed if nftables allows it
- We add explicit nftables DNAT rules ONLY for ports that must be exposed

### Bind Address Discipline

All containers that are WG-only must bind to the WG IP, not `0.0.0.0`:

```yaml
# WRONG — exposes to all interfaces
ports:
  - "8081:8081"

# RIGHT — WG-only
ports:
  - "10.0.0.6:8081:8081"
```

---

## Public Allowlist (Per VM)

These are the ONLY ports nftables will open. Everything else is DROP.

### gcp-proxy (35.226.147.64)

| Proto | Port | Service |
|-------|------|---------|
| TCP | 80 | Caddy HTTP (Cloudflare → Caddy) |
| TCP | 443 | Caddy HTTPS |
| UDP | 443 | QUIC (HTTP/3) |
| UDP | 51820 | WireGuard |

> SSH (22) → WG-only. Access via `ssh gcp-proxy` after connecting to WG.
> Emergency access: GCP console SSH.

### oci-mail (130.110.251.193)

| Proto | Port | Service |
|-------|------|---------|
| TCP | 25 | SMTP inbound (other mail servers) |
| TCP | 465 | SMTPS (mail clients) |
| TCP | 587 | SMTP submission (mail clients) |
| TCP | 993 | IMAPS (mail clients) |
| TCP | 22000 | Syncthing transfer |
| UDP | 21027 | Syncthing discovery |
| UDP | 51820 | WireGuard |

> SSH (22) → WG-only. Emergency: OCI console.

### oci-analytics (129.151.228.66)

| Proto | Port | Service |
|-------|------|---------|
| UDP | 51820 | WireGuard |

> Cleanest VM. SSH → WG-only. Emergency: OCI console.

### oci-apps (82.70.229.129)

| Proto | Port | Service |
|-------|------|---------|
| UDP | 51820 | WireGuard |

> **Everything goes through gcp-proxy → WG → oci-apps.**
> C3 API, Rust API, Crawlee, Gitea, Backup SSH, PostgreSQL — all WG-only.
> Emergency SSH: OCI console.

---

## Phase 1: Caddy Upstream Audit (gcp-proxy)

**Check all Caddy service routes that use public IPs instead of WG IPs.**

Known issue pattern:
```
# WRONG — routes to public IP (extra hop, bypasses WG encryption)
reverse_proxy 82.70.229.129:8081

# CORRECT — routes via WG tunnel
reverse_proxy 10.0.0.6:8081
```

### Steps

1. Read `bb-sec_caddy/src/flake.nix` — grep for public IPs (82.70.229.129, 130.110.251.193, etc.)
2. Replace all public IP upstreams with corresponding WG IPs:
   - `82.70.229.129` → `10.0.0.6` (oci-apps)
   - `130.110.251.193` → `10.0.0.3` (oci-mail)
   - `129.151.228.66` → `10.0.0.4` (oci-analytics)
   - `144.24.196.72` → `10.0.0.2` (oci-apps-1, decommissioned)
3. `build.sh ship` for caddy

---

## Phase 2: Disable Docker iptables

**Source**: `cloud/b_infra/home-manager/` — docker daemon config module

All VMs with Docker/Podman need `iptables: false` in daemon config.

```nix
# In home-manager module or docker-service.nix
virtualisation.docker.daemon.settings = {
  iptables = false;
};
```

Or for the docker-service.nix pattern (oci-apps uses custom module):
```nix
# daemon.json written by nix activation
{
  "iptables": false,
  "userland-proxy": false
}
```

### Steps

4. Update `cloud/b_infra/home-manager/modules/docker-service.nix` — add `iptables: false` to daemon.json generation
5. Update any other VM docker configs
6. Deploy via home-manager GHA

---

## Phase 3: Declarative nftables Firewall

Replace the current `networking.firewall` (iptables-based, Docker-polluted) with a pure nftables module that loads **before Docker**.

### Nix Module: `modules/nftables-firewall.nix`

Per-VM config passed in via home-manager:

```nix
# Template — parameterized per VM
{ config, lib, pkgs, vmConfig, ... }:
{
  networking.nftables.enable = true;
  networking.firewall.enable = false;  # disable iptables-based firewall

  networking.nftables.ruleset = ''
    table inet filter {
      chain input {
        type filter hook input priority filter; policy drop;

        # Loopback
        iif "lo" accept

        # Established/related
        ct state established,related accept

        # ICMP (ping)
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept

        # WireGuard
        udp dport 51820 accept comment "WireGuard"

        # VM-specific public ports (injected from vmConfig.publicPorts)
        ${lib.concatMapStrings (rule: "${rule}\n") vmConfig.publicPorts}

        # Everything else: DROP (logged)
        log prefix "nft-drop: " drop
      }

      chain forward {
        type filter hook forward priority filter; policy drop;

        # WireGuard traffic forwarding
        iifname "wg0" accept
        oifname "wg0" accept

        # Docker container-to-container (same host)
        iifname "docker0" oifname "docker0" accept
        ct state established,related accept
      }

      chain output {
        type filter hook output priority filter; policy accept;
      }
    }

    table ip nat {
      chain postrouting {
        type nat hook postrouting priority srcnat;

        # WireGuard masquerade
        oifname "wg0" masquerade
      }
    }
  '';

  # Load nftables BEFORE Docker starts
  systemd.services.nftables = {
    before = [ "docker.service" "wg-quick@wg0.service" ];
    wantedBy = [ "multi-user.target" ];
  };
}
```

### Per-VM public port lists

```nix
# gcp-proxy
publicPorts = [
  "tcp dport 80 accept comment \"Caddy HTTP\""
  "tcp dport 443 accept comment \"Caddy HTTPS\""
  "udp dport 443 accept comment \"QUIC\""
];

# oci-mail
publicPorts = [
  "tcp dport 25 accept comment \"SMTP inbound\""
  "tcp dport 465 accept comment \"SMTPS\""
  "tcp dport 587 accept comment \"SMTP submission\""
  "tcp dport 993 accept comment \"IMAPS\""
  "tcp dport 22000 accept comment \"Syncthing transfer\""
  "udp dport 21027 accept comment \"Syncthing discovery\""
];

# oci-analytics
publicPorts = [];  # WG-only

# oci-apps
publicPorts = [];  # WG-only
```

### Steps

7. Create `cloud/b_infra/home-manager/modules/nftables-firewall.nix`
8. Set `networking.firewall.enable = false` for all VMs
9. Set `networking.nftables.enable = true`
10. Wire per-VM port lists in `cloud/b_infra/home-manager/hosts/*.nix`
11. Deploy via home-manager GHA — **test one VM first** (oci-analytics safest, WG-only)

---

## Phase 4: Fix Service Bind Addresses

All docker-compose services must bind to WG IP, not `0.0.0.0`.

### oci-apps — services to fix

| Service | Current bind | Fix to |
|---------|-------------|--------|
| C3 API (8081) | `0.0.0.0:8081` | `10.0.0.6:8081` |
| Rust API (8080) | `0.0.0.0:8080` | `10.0.0.6:8080` |
| Crawlee (3000) | `0.0.0.0:3000` | `10.0.0.6:3000` |
| Crawlee API (3001) | `0.0.0.0:3001` | `10.0.0.6:3001` |
| PostgreSQL (5432) | `0.0.0.0:5432` | `10.0.0.6:5432` |
| PostgreSQL (5433,5434) | `0.0.0.0:543x` | `10.0.0.6:543x` |
| Redis (6380) | `0.0.0.0:6380` | `127.0.0.1:6380` (loopback) |
| MinIO (9000,9001) | `0.0.0.0:900x` | `10.0.0.6:900x` |
| Loki (3100-3103,3080) | `0.0.0.0:3xxx` | `10.0.0.6:3xxx` |
| Gitea SSH (2222) | `0.0.0.0:2222` | `10.0.0.6:2222` |
| Backup SSH (2223,2224) | `0.0.0.0:222x` | `10.0.0.6:222x` |
| 8050, 8082, 8889 | `0.0.0.0` | `10.0.0.6` |

### oci-mail — services to fix

| Service | Current bind | Fix to |
|---------|-------------|--------|
| Mailu web (8080) | `0.0.0.0:8080` | `10.0.0.3:8080` |
| Mailu HTTPS (443) | `0.0.0.0:443` | `10.0.0.3:443` |
| Mailu (80, 8880, 8443, 8088) | `0.0.0.0` | `10.0.0.3` |

### gcp-proxy — services to fix

| Service | Current bind | Fix to |
|---------|-------------|--------|
| Authelia (9091) | `0.0.0.0:9091` | `10.0.0.1:9091` |
| introspect-proxy (9999) | `0.0.0.0:9999` | `10.0.0.1:9999` |

### Steps

12. For each service flake.nix, update `ports:` in docker-compose template:
    `"PORT:PORT"` → `"10.0.0.X:PORT:PORT"`
13. `build.sh ship` per service (or push to main for GHA auto-deploy)

---

## Phase 5: Disable rpcbind

rpcbind (port 111) has no purpose on these VMs. Disable it declaratively.

```nix
# In home-manager or NixOS config
services.rpcbind.enable = false;
systemd.services.rpcbind.enable = false;
```

### Steps

14. Add `services.rpcbind.enable = false` to all VM home-manager configs
15. Deploy

---

## Phase 6: PostgreSQL 5432

Remove from public firewall (already handled by Phase 3 — oci-apps has no public ports).
Fix bind address to `10.0.0.6` (Phase 4).

If the "Photos webhook DB" use case requires external write access:
- **Option A**: Create a minimal API endpoint in front of the DB (preferred)
- **Option B**: Whitelist specific source IPs in pg_hba.conf (defense in depth, but still bad)
- **Option C**: External service connects via WireGuard peer

---

## Phase 7: SSH Hardening

Move SSH off public internet — access only via WireGuard.

### Steps

16. Confirm OCI/GCP serial console access works for emergency recovery
17. Update nftables: remove SSH (22) from all public allowlists
18. All VMs: SSH accessible via `10.0.0.X:22` (WG tunnel only)
19. Deploy nftables (Phase 3) includes no port 22 in public rules

> **Safety**: Deploy to oci-analytics first (lowest risk). Verify WG tunnel stays up after reboot. Then roll out to others.

---

## Phase 8: Verification

After full deployment:

```bash
# From internet (should all fail except the allowed public ports)
nmap -p 22,80,443,8080,8081,5432,9091 82.70.229.129   # oci-apps: only WG should open
nmap -p 22,80,443,8080 35.226.147.64                   # gcp-proxy: only 80,443

# From WG peer (these should work)
curl http://10.0.0.6:8081/health        # C3 API via WG
psql -h 10.0.0.6 -p 5432 ...           # PostgreSQL via WG

# Verify Docker cannot write iptables
ssh oci-apps 'sudo iptables -L DOCKER 2>&1 || echo "DOCKER chain gone — correct"'
ssh oci-apps 'sudo nft list ruleset | grep -c "accept" '

# Verify nftables loaded before Docker
ssh oci-apps 'sudo systemctl list-dependencies --before docker.service | grep nftables'
```

---

## Deployment Order (Safe Rollout)

1. **Phase 1** (Caddy fix) — no downtime, just routing fix
2. **Phase 3 + Phase 5** on **oci-analytics** — safest VM, WG-only already
3. **Phase 3 + Phase 4 + Phase 5** on **oci-mail** — mail ports stay public
4. **Phase 2 + Phase 3 + Phase 4 + Phase 5 + Phase 6** on **oci-apps** — most changes
5. **Phase 3 + Phase 5** on **gcp-proxy** — last, most critical VM
6. **Phase 7** (SSH) — after all above confirmed stable for 24h

---

## Files Modified

| File | Change |
|------|--------|
| `cloud/b_infra/home-manager/modules/nftables-firewall.nix` | NEW — declarative nftables module |
| `cloud/b_infra/home-manager/modules/docker-service.nix` | Add `iptables: false` to daemon.json |
| `cloud/b_infra/home-manager/hosts/*.nix` (×4 VMs) | Wire nftables module, disable iptables firewall, per-VM port lists |
| `cloud/a_solutions/bb-sec_caddy/src/flake.nix` | Fix upstreams: public IPs → WG IPs |
| `cloud/a_solutions/bc-obs_c3-mcp-api/src/flake.nix` | Bind ports to `10.0.0.6` |
| `cloud/a_solutions/bb-sec_rust-api/src/flake.nix` | Bind ports to `10.0.0.6` |
| `cloud/a_solutions/bc-obs_crawlee/src/flake.nix` | Bind ports to `10.0.0.6` |
| `cloud/a_solutions/ca-dat_postgres/src/flake.nix` | Bind to `10.0.0.6`, remove from FW |
| `cloud/a_solutions/ca-dat_redis/src/flake.nix` | Bind to `127.0.0.1` |
| `cloud/a_solutions/bc-obs_loki/src/flake.nix` | Bind to `10.0.0.6` |
| `cloud/a_solutions/aa-sui_mailu/src/flake.nix` | Bind internal ports to `10.0.0.3` |
| `cloud/a_solutions/bb-sec_authelia/src/flake.nix` | Bind to `10.0.0.1` |
| `cloud/a_solutions/bb-sec_introspect-proxy/src/flake.nix` | Bind to `10.0.0.1` |

---

## Security Model After Completion

```
Internet
  │
  ├─→ gcp-proxy:80/443    (Caddy — only entry for web traffic)
  ├─→ oci-mail:25/465/587/993  (Mail protocols — required by RFC)
  ├─→ oci-mail:22000       (Syncthing)
  └─→ all VMs:51820/udp   (WireGuard — VPN entry)

WireGuard Tunnel (10.0.0.0/24)
  ├─→ All services accessible to authenticated WG peers
  └─→ gcp-proxy routes all web subdomains → WG → target VM

nftables (loaded before Docker, permanent)
  ├─→ INPUT: policy DROP + explicit allowlist only
  ├─→ FORWARD: policy DROP + WG + docker0 internal
  └─→ Docker iptables: DISABLED — Docker cannot bypass nftables
```

**Invariant**: A port not in the nftables allowlist is unreachable from the internet, regardless of what Docker, any service, or any container attempts to bind or expose.
