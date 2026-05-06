# Declarative Networking + Firewall Sovereign Lockdown

> **Date**: 2026-03-18
> **Updated**: 2026-03-18
> **Status**: Planning complete, implementation pending
> **Merges**: TASK-04 (Declarative Networking) + TASK-08 (Firewall Lockdown)
> **Correction**: All firewall rules use **nftables** (not iptables). Docker `iptables: false` stays.

**Root Cause**: Docker with `iptables: false` loses container DNS resolution and port forwarding. Docker engine restart/reboot wipes DNAT rules. Setting `iptables: true` conflicts with our declarative firewall. Solution: we own ALL networking — DNS, IPs, firewall, DNAT — Docker only runs containers.

---

## Checklist

### Phase 1: Data layer (no deployment, no downtime)
- [ ] Create `mesh-topology.nix` — extract peer data from current wireguard.nix
- [ ] Add `auth` blocks to all service `build.json` files
- [ ] Add `containerNetwork` to all VM `.nix` files

### Phase 2: C3 parsers (read-only, no deployment impact)
- [ ] Create `mesh-topology.ts` parser
- [ ] Create `container-network.ts` parser
- [ ] Extend `build-json.ts` — parse new `auth` field
- [ ] Update `gen-topology.ts` — use new parsers
- [ ] Update `gen-configs.ts` — auth from build.json + drift detection
- [ ] Update `build.sh cmd_config()` — nix eval exports
- [ ] Verify: `build.sh config` output matches current topology/configs JSON

### Phase 3: Home-manager modules (deploy to test VM first)
- [ ] Create docker-network.nix module
- [ ] Create dnsmasq.nix module
- [ ] Create web-server-busybox.nix module
- [ ] Create nftables-firewall.nix module (replaces iptables-based firewall.nix)
- [ ] Update wireguard.nix — read from `meshTopology`
- [ ] Add `"iptables": false` to docker daemon.json (docker-service.nix)
- [ ] Push home-manager for oci-analytics first (safest, WG-only)
- [ ] Verify: WG mesh, nftables rules, dnsmasq resolves

### Phase 4: Service flakes (one VM at a time)
- [ ] Rebuild Caddy with caddy-l4 plugin
- [ ] Update Caddy flake — auto-generate Caddyfile + fix all upstreams to WG IPs
- [ ] Update Authelia flake — auto-generate ACL + OIDC audience
- [ ] Update all service docker-compose: bind ports to WG IP, fixed container IPs
- [ ] Disable rpcbind on all VMs
- [ ] Ship per-VM, verify each before next

### Phase 5: SSH hardening + Cleanup
- [ ] Confirm cloud console SSH works on all VMs (emergency access)
- [ ] Remove SSH (port 22) from public nftables allowlist — WG-only
- [ ] Deploy wstunnel + Caddy L4 for port 443 fallback
- [ ] Delete deprecated parsers (ssh-config.ts, wireguard.ts regex)
- [ ] Update GHA workflow trigger paths

---

## Architecture After

```
Internet
  |
  +-> gcp-proxy:80/443     (Caddy — only web entry point)
  +-> oci-mail:25/465/587/993  (Mail — required by RFC)
  +-> oci-mail:22000        (Syncthing)
  +-> all VMs:51820/udp     (WireGuard)
  |
  X  Everything else: DROP (nftables policy)
  |
WireGuard Tunnel (10.0.0.0/24)
  +-> All services accessible to authenticated WG peers
  +-> Caddy routes subdomains -> WG -> target VM
  |
Per-VM: nftables (loaded before Docker, permanent)
  +-> INPUT: policy drop + explicit allowlist
  +-> FORWARD: policy drop + WG + docker networks
  +-> Docker iptables: DISABLED — cannot bypass nftables
  |
Per-VM: Docker Networks (fixed IPs, trust-boundary isolation)
  +-> apps (shared /27): standalone services
  +-> isolated (/28 each): services with own DB
  +-> dnsmasq on host: container DNS on bridge gateways
```

---

## Key Design Principles

1. `iptables: false` in Docker — we own all networking, not Docker
2. **nftables** (not iptables) as the sole firewall — loaded by systemd Before=docker.service
3. Three sources of truth: `meshTopology` (shared) + `containerNetwork` (per-VM) + `build.json` auth (per-service)
4. Trust-boundary isolation: services with own DB get private network, standalone services share `apps`
5. dnsmasq runs on host (systemd), not inside Docker — no circular dependency
6. Caddy is the bouncer — all cross-VM traffic goes through Caddy over WG
7. Two-layer bind model: containers get fixed Docker IPs (172.x) + host ports bind to WG IP (10.0.0.x) as defense-in-depth
8. Each service owns its auth — declared in `build.json`, Caddy/Authelia configs auto-generated

---

## Public Port Allowlist (ONLY these ports open to internet)

### gcp-proxy (35.226.147.64)

| Proto | Port | Service |
|-------|------|---------|
| TCP | 80 | Caddy HTTP |
| TCP | 443 | Caddy HTTPS |
| UDP | 443 | QUIC (HTTP/3) |
| UDP | 51820 | WireGuard |

### oci-mail (130.110.251.193)

| Proto | Port | Service |
|-------|------|---------|
| TCP | 25 | SMTP inbound |
| TCP | 465 | SMTPS |
| TCP | 587 | SMTP submission |
| TCP | 993 | IMAPS |
| TCP | 22000 | Syncthing transfer |
| UDP | 21027 | Syncthing discovery |
| UDP | 51820 | WireGuard |

### oci-analytics (129.151.228.66)

| Proto | Port | Service |
|-------|------|---------|
| UDP | 51820 | WireGuard |

### oci-apps (82.70.229.129)

| Proto | Port | Service |
|-------|------|---------|
| UDP | 51820 | WireGuard |

> SSH (port 22) is WG-only on ALL VMs. Emergency access via cloud console.

---

## nftables Firewall Module

Replaces the iptables-based `firewall.nix`. This is the SOLE source of truth for network access.

### Module: `modules/nftables-firewall.nix`

```nix
{ vmName, publicPorts ? [], containerNetwork ? null, meshTopology ? null }:
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

        # ICMP
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept

        # WireGuard (always allowed)
        udp dport 51820 accept comment "WireGuard"

        # WG interface — allow all traffic from tunnel peers
        iifname "wg0" accept comment "WireGuard tunnel traffic"

        # VM-specific public ports (injected from config)
        ${lib.concatMapStrings (rule: "${rule}\n") publicPorts}

        # Log + drop everything else
        log prefix "nft-drop: " drop
      }

      chain forward {
        type filter hook forward priority filter; policy drop;

        # WireGuard forwarding (scoped to container subnets)
        iifname "wg0" accept
        oifname "wg0" accept

        # Docker container-to-container (per declared network)
        ${lib.concatMapStrings (name: net: ''
          iifname "br-*" oifname "br-*" ip daddr ${net.subnet} accept comment "${name}"
        '') (lib.mapAttrsToList (n: v: v // { name = n; }) containerNetwork.networks)}

        # Established return traffic
        ct state established,related accept
      }

      chain output {
        type filter hook output priority filter; policy accept;
      }
    }

    table ip nat {
      chain prerouting {
        type nat hook prerouting priority dstnat;

        # Auto-generated DNAT from containerNetwork.containers with ports
        ${lib.concatMapStrings (c:
          lib.concatMapStrings (port: ''
            iifname "wg0" tcp dport ${toString port} dnat to ${c.ip}:${toString port} comment "${c.name}"
          '') (c.ports or [])
        ) (lib.mapAttrsToList (n: v: v // { name = n; }) containerNetwork.containers)}
      }

      chain postrouting {
        type nat hook postrouting priority srcnat;
        oifname "wg0" masquerade
        # Masquerade for Docker networks
        ${lib.concatMapStrings (name: net: ''
          ip saddr ${net.subnet} oifname != "br-*" masquerade comment "${name}"
        '') (lib.mapAttrsToList (n: v: v // { name = n; }) containerNetwork.networks)}
      }
    }
  '';

  # Load BEFORE Docker
  systemd.services.nftables = {
    before = [ "docker.service" ];
    wantedBy = [ "multi-user.target" ];
  };
}
```

### Per-VM public port config

```nix
# gcp-proxy
publicPorts = [
  ''tcp dport 80 accept comment "Caddy HTTP"''
  ''tcp dport 443 accept comment "Caddy HTTPS"''
  ''udp dport 443 accept comment "QUIC"''
];

# oci-mail
publicPorts = [
  ''tcp dport 25 accept comment "SMTP inbound"''
  ''tcp dport 465 accept comment "SMTPS"''
  ''tcp dport 587 accept comment "SMTP submission"''
  ''tcp dport 993 accept comment "IMAPS"''
  ''tcp dport 22000 accept comment "Syncthing transfer"''
  ''udp dport 21027 accept comment "Syncthing discovery"''
];

# oci-analytics — no public ports (WG-only)
publicPorts = [];

# oci-apps — no public ports (WG-only)
publicPorts = [];
```

---

## Docker Daemon: iptables disabled

```nix
# In docker-service.nix
# daemon.json
{
  "iptables": false,
  "userland-proxy": false
}
```

**Consequence**: Docker `ports:` mappings still bind host ports via runc, but traffic only reaches them if nftables allows it. All DNAT is handled by nftables, not Docker.

---

## Service Bind Discipline (Two-Layer Model)

**Layer 1**: Docker compose `ports:` bind to WG IP (defense-in-depth on host)
**Layer 2**: Container gets fixed IP in Docker network (from containerNetwork)

```yaml
# WRONG — exposes to all interfaces
ports:
  - "8081:8081"

# RIGHT — WG-only host bind + fixed container IP
ports:
  - "10.0.0.6:8081:8081"
networks:
  apps:
    ipv4_address: 172.21.0.2
dns:
  - 172.21.0.1  # dnsmasq on bridge gateway
```

### Services to fix (oci-apps)

| Service | Current | Fix to |
|---------|---------|--------|
| C3 API (8081) | 0.0.0.0 | 10.0.0.6:8081 |
| Rust API (8080) | 0.0.0.0 | 10.0.0.6:8080 |
| Crawlee (3000,3001) | 0.0.0.0 | 10.0.0.6:300x |
| PostgreSQL (5432-5434) | 0.0.0.0 | 10.0.0.6:543x |
| Redis (6380) | 0.0.0.0 | 127.0.0.1:6380 |
| MinIO (9000,9001) | 0.0.0.0 | 10.0.0.6:900x |
| Loki (3100-3103,3080) | 0.0.0.0 | 10.0.0.6:3xxx |
| Gitea SSH (2222) | 0.0.0.0 | 10.0.0.6:2222 |

### Services to fix (gcp-proxy)

| Service | Current | Fix to |
|---------|---------|--------|
| Authelia (9091) | 0.0.0.0 | 10.0.0.1:9091 |
| introspect-proxy (9999) | 0.0.0.0 | 10.0.0.1:9999 |

### Services to fix (oci-mail)

| Service | Current | Fix to |
|---------|---------|--------|
| Mailu internal (80,443,8443,8880,8088) | 0.0.0.0 | 10.0.0.3 |

---

## Disable rpcbind

Port 111 has no purpose. Disable on all VMs:

```nix
services.rpcbind.enable = false;
systemd.services.rpcbind.enable = false;
```

---

## Network Design: Trust Boundary Isolation

(Full detail from original TASK-04)

### Subnet Allocation

| VM | Block | Shared (/27) | Isolated (/28s) |
|----|-------|-------------|-----------------|
| gcp-proxy | 172.20.0.0/16 | 172.20.0.0/27 | 172.20.0.32/28 |
| oci-apps | 172.21.0.0/16 | 172.21.0.0/27 | .32, .48, .64, .80, .96, .112 |
| oci-mail | 172.22.0.0/16 | 172.22.0.0/27 | 172.22.0.32/28 |
| oci-analytics | 172.23.0.0/16 | 172.23.0.0/27 | .32, .48 |
| oci-apps-2 | 172.24.0.0/16 | 172.24.0.0/27 | — |
| gcp-t4 | 172.25.0.0/16 | 172.25.0.0/27 | — |

**Rule**: Services with own DB get isolated /28 network. App container bridges to `apps` via `also = ["apps"]`. DB containers stay on private network ONLY.

```
                    +---------------------------------------------+
                    |              apps (shared /27)               |
                    |  caddy, authelia, c3-api, gitea, ntfy, ...  |
                    +---------------------------------------------+
                         ^ can't reach v           ^ can't reach v
    +----------------------+  +----------------------+  +----------------------+
    |  mattermost (/28)    |  |  nocodb (/28)        |  |  photoprism (/28)    |
    |  app + postgres      |  |  app + postgres      |  |  app + mariadb       |
    +----------------------+  +----------------------+  +----------------------+
```

---

## Three Data Sources

### 1. `mesh-topology.nix` (shared)

```nix
{
  peers = {
    gcp-proxy     = { wgIp = "10.0.0.1";  endpoint = "35.226.147.64:51820";  role = "hub"; };
    oci-apps      = { wgIp = "10.0.0.6";  endpoint = "82.70.229.129:51820";  role = "spoke"; };
    oci-mail      = { wgIp = "10.0.0.3";  endpoint = "130.110.251.193:51820"; role = "spoke"; };
    oci-analytics = { wgIp = "10.0.0.4";  endpoint = "129.151.228.66:51820"; role = "spoke"; };
  };
  wgSubnet = "10.0.0.0/24";
  wgPort = 51820;
}
```

Consumed by: wireguard.nix, dnsmasq.nix, nftables-firewall.nix, Caddy flake (upstream IPs).

### 2. `containerNetwork` (per-VM)

```nix
containerNetwork = {
  networks = {
    apps       = { subnet = "172.21.0.0/27";  gateway = "172.21.0.1"; };
    mattermost = { subnet = "172.21.0.32/28"; gateway = "172.21.0.33"; };
  };
  containers = {
    c3-api              = { ip = "172.21.0.2";  network = "apps"; ports = [ 8081 ]; };
    mattermost          = { ip = "172.21.0.34"; network = "mattermost"; also = [ "apps" ]; ports = [ 8065 ]; };
    mattermost-postgres = { ip = "172.21.0.35"; network = "mattermost"; };  # DB — private only
  };
};
```

Consumed by: docker-network.nix, dnsmasq.nix, nftables-firewall.nix (DNAT), service flakes.

### 3. `build.json` auth (per-service)

```json
{
  "auth": {
    "domain": "api.diegonmarcos.com",
    "path_prefix": "/c3-api",
    "policy": "two_factor",
    "bearer": true,
    "public": ["/c3-api/docs"]
  }
}
```

Consumed by: Caddy flake (routes), Authelia flake (ACL), OIDC audience list.

### How all three flow

```
mesh-topology.nix     containerNetwork      build.json auth
        |                     |                     |
        +-> wireguard.nix     +-> docker-network    +-> Caddy flake
        +-> dnsmasq.nix       +-> dnsmasq.nix       +-> Authelia flake
        +-> nftables-firewall +-> nftables-firewall  +-> OIDC audience
        +-> Caddy (upstreams) +-> service flakes
```

---

## dnsmasq on Host (systemd, not Docker)

- Runs as systemd service, `Before=docker.service`
- Listens on ALL Docker bridge gateway IPs (172.x.y.1) + 127.0.0.1
- NOT on public IP or WG IP
- Resolves: container names -> fixed IPs, VM names -> WG IPs, else -> upstream (1.1.1.1)
- Every container gets `dns: ["${gateway_ip}"]` in docker-compose

---

## Port 443 Fallback (Caddy L4 + wstunnel)

For restrictive networks that block UDP 51820 and TCP 22:

```
Airport WiFi :443 -> Caddy L4 --+-- SSH bytes -> sshd :22
                                 +-- TLS ClientHello -> Caddy HTTPS :8443
                                                            |
                                        wg-tunnel.diegonmarcos.com (WSS)
                                                            |
                                                    wstunnel server
                                                            |
                                                  unwrap UDP -> WG :51820
```

---

## Caddy Upstream Fix (Phase 4 prerequisite)

All Caddy routes must use WG IPs, not public IPs:

```
# WRONG
reverse_proxy 82.70.229.129:8081

# RIGHT (auto-generated from meshTopology)
reverse_proxy 10.0.0.6:8081
```

---

## Deployment Order (Safe Rollout)

1. Phase 1 + 2: Data layer + parsers (zero risk, no deployment)
2. Phase 3 on **oci-analytics** first (safest VM, WG-only, fewest services)
3. Phase 3 + 4 on **oci-mail** (mail ports stay public)
4. Phase 3 + 4 on **oci-apps** (most services, most changes)
5. Phase 3 + 4 on **gcp-proxy** last (most critical VM)
6. Phase 5: SSH hardening after all above stable for 24h

**Rule: one VM at a time. Never push all VMs simultaneously.**

---

## Verification

1. `nmap -p 22,80,443,8080,8081,5432,9091 82.70.229.129` — only WG port open on oci-apps
2. `nmap -p 22,80,443,8080 35.226.147.64` — only 80,443 on gcp-proxy
3. From WG: `curl http://10.0.0.6:8081/health` — works
4. `ssh oci-apps 'sudo nft list ruleset'` — shows our declared rules only
5. `ssh oci-apps 'sudo iptables -L DOCKER 2>&1'` — chain doesn't exist (Docker iptables disabled)
6. All services healthy after deployment

---

## Files Modified

| File | Change |
|------|--------|
| `b_infra/_shared/mesh-topology.nix` | NEW — WG mesh source of truth |
| `b_infra/_shared/modules/nftables-firewall.nix` | NEW — replaces iptables firewall.nix |
| `b_infra/_shared/modules/docker-network.nix` | NEW — fixed Docker networks |
| `b_infra/_shared/modules/dnsmasq.nix` | NEW — host DNS for containers |
| `b_infra/_shared/modules/web-server-busybox.nix` | NEW — WG-only httpd |
| `b_infra/_shared/modules/docker-service.nix` | EDIT — `iptables: false` in daemon.json |
| `b_infra/_shared/wireguard.nix` | EDIT — read from meshTopology |
| `b_infra/*/src/*.nix` (x6 VMs) | EDIT — import meshTopology, add containerNetwork, publicPorts |
| Every service `build.json` | EDIT — add `auth` block |
| Every service `flake.nix` | EDIT — bind ports to WG IP, fixed container IPs, dns gateway |
| `bb-sec_caddy/src/flake.nix` | EDIT — auto-generate routes from build.json + meshTopology upstreams + L4 |
| `bb-sec_caddy/src/Dockerfile` | EDIT — rebuild with caddy-l4 plugin |
| `bb-sec_authelia/src/flake.nix` | EDIT — auto-generate ACL from build.json auth |
| `bb-sec_wstunnel/` | NEW — wstunnel server service |
| C3 parsers: mesh-topology.ts, container-network.ts | NEW |
| C3 parsers: ssh-config.ts | DELETE |
| C3 parsers: build-json.ts, gen-topology.ts, gen-configs.ts | EDIT |

---

## Security Model After Completion

**Invariant**: A port not in the nftables allowlist is unreachable from the internet, regardless of what Docker, any service, or any container attempts to bind or expose.

**Total public ports across all VMs**: 7 (down from ~40)
- gcp-proxy: 3 (80, 443, 443/udp)
- oci-mail: 6 (25, 465, 587, 993, 22000, 21027/udp)
- oci-analytics: 0
- oci-apps: 0
- Plus WireGuard 51820/udp on all
