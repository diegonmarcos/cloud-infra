# Plan: Docker DNS + Fixed IPs + Declarative Networking

**Date**: 2026-03-09
**Updated**: 2026-03-09 (v2 — reviewed architecture)
**Root Cause**: Docker with `iptables: false` loses container DNS resolution and port forwarding. Docker engine restart/reboot wipes DNAT rules. Setting `iptables: true` conflicts with our declarative firewall.nix.

**Goal**: Full declarative control — we own DNS, IPs, firewall rules. Docker only runs containers.

**Design Principles**:
1. `iptables: false` stays — we own all networking, not Docker
2. **Single source of truth** — IP allocations defined once in VM config, consumed by docker-compose, dnsmasq, and firewall
3. **Network isolation preserved** — per-service networks with fixed subnets, not one flat network
4. **No circular dependencies** — dnsmasq runs on host (systemd), not inside Docker

---

## Current State

| Component | Current | Problem |
|-----------|---------|---------|
| Docker daemon | `iptables: false` in daemon.json | No auto DNAT/DNS for containers |
| Container DNS | Docker embedded DNS (broken with iptables:false) | Containers can't resolve each other by name |
| Container IPs | DHCP (random from 172.17.0.0/16) | IPs change on restart, can't write static firewall rules |
| Docker networks | `npm_default` (external, no subnet control) | No fixed IPs, no DNS |
| Hickory DNS | `.internal` zone on 10.0.0.1:53 (WG only) | Only VM-level resolution, not container-level |
| Firewall | firewall.nix owns INPUT/FORWARD/NAT | Works, but docker-proxy is unreliable for port exposure |
| Web server | busybox httpd.nix (only on oci-apps for cloud-spec) | Not deployed on all VMs |

---

## Architecture After

```
Internet → Cloudflare → gcp-proxy:443 → Caddy → WireGuard mesh
                                                      │
                                           ┌──────────┼──────────┐
                                           │          │          │
                                      gcp-proxy  oci-apps   oci-mail  ...
                                           │          │          │
                                      dnsmasq     dnsmasq    dnsmasq
                                      (systemd)   (systemd)  (systemd)
                                      on bridge   on bridge  on bridge
                                      gateway IP  gateway IP gateway IP
                                           │          │          │
                                      ┌────┘    ┌────┘    ┌────┘
                                      │         │         │
                                   containers  containers containers
                                   (fixed IP)  (fixed IP) (fixed IP)
                                   per-service per-service per-service
                                   networks    networks    networks
```

Key differences from v1:
- dnsmasq is a **systemd service on the host**, not a Docker container
- Per-service networks (not one flat `infra`), each with fixed subnets
- IP allocation defined **once** in VM nix config, flows to all consumers

---

## Step 1: Central IP Allocation in VM Config

### Single source of truth

Each VM's nix config defines ALL container IPs, network assignments, and port mappings. This data flows into:
- Docker compose templates (via `ipv4_address`)
- dnsmasq config (via `host-record` entries)
- Firewall DNAT rules (via `iptables -t nat`)

### Data structure (in each VM's `.nix` file)

```nix
containerNetwork = {
  # Per-service networks (isolation preserved)
  networks = {
    proxy  = { subnet = "172.20.1.0/24"; gateway = "172.20.1.1"; };
    auth   = { subnet = "172.20.2.0/24"; gateway = "172.20.2.1"; };
    vault  = { subnet = "172.20.3.0/24"; gateway = "172.20.3.1"; };
    ntfy   = { subnet = "172.20.4.0/24"; gateway = "172.20.4.1"; };
    dns    = { subnet = "172.20.5.0/24"; gateway = "172.20.5.1"; };
  };

  # Container → IP + network + exposed ports
  containers = {
    caddy            = { ip = "172.20.1.10"; network = "proxy"; ports = [ 80 443 ]; };
    introspect-proxy = { ip = "172.20.1.11"; network = "proxy"; };
    authelia         = { ip = "172.20.2.10"; network = "auth";  ports = [ 9091 ]; };
    redis            = { ip = "172.20.2.11"; network = "auth";  };
    vaultwarden      = { ip = "172.20.3.10"; network = "vault"; ports = [ 80 ]; };
    ntfy             = { ip = "172.20.4.10"; network = "ntfy";  ports = [ 8090 ]; };
    hickory-dns      = { ip = "172.20.5.10"; network = "dns";   ports = [ 53 ]; };
  };

  # Cross-network links (containers that need to talk across service boundaries)
  links = [
    { from = "caddy"; to = "auth"; }     # Caddy → Authelia for forward auth
    { from = "caddy"; to = "vault"; }    # Caddy → Vaultwarden upstream
    { from = "caddy"; to = "ntfy"; }     # Caddy → ntfy upstream
    { from = "authelia"; to = "proxy"; } # Authelia → introspect-proxy
  ];
};
```

Cross-network links: containers that need to reach other service networks get attached to both. This is done in docker-compose via multiple `networks:` entries. Isolation is maintained — only explicitly linked containers can cross boundaries.

### How it flows

```
VM nix config (containerNetwork)
        │
        ├──→ service flake.nix reads from it → docker-compose.yml (ipv4_address, dns)
        ├──→ dnsmasq.nix reads from it → /etc/dnsmasq.d/containers.conf (host-record)
        └──→ firewall.nix reads from it → iptables DNAT + FORWARD rules
```

The service flake.nix doesn't hardcode IPs — it receives them as build inputs or reads from a shared config file generated by the VM's home-manager activation.

---

## Step 2: Per-Service Docker Networks with Fixed Subnets

### Subnet Allocation Scheme

Each VM gets a /16 block. Each service gets a /24 within it.

| VM | Block | Service networks within |
|----|-------|------------------------|
| gcp-proxy | 172.20.0.0/16 | 172.20.1-5.0/24 |
| oci-apps | 172.21.0.0/16 | 172.21.1-15.0/24 |
| oci-mail | 172.22.0.0/16 | 172.22.1-5.0/24 |
| oci-analytics | 172.23.0.0/16 | 172.23.1-3.0/24 |
| oci-apps-2 | 172.24.0.0/16 | 172.24.1-5.0/24 |
| gcp-t4 | 172.25.0.0/16 | 172.25.1-3.0/24 |

### gcp-proxy (172.20.0.0/16)

| Network | Subnet | Containers | IPs |
|---------|--------|------------|-----|
| `proxy` | 172.20.1.0/24 | caddy, introspect-proxy | .10, .11 |
| `auth` | 172.20.2.0/24 | authelia, redis | .10, .11 |
| `vault` | 172.20.3.0/24 | vaultwarden | .10 |
| `ntfy` | 172.20.4.0/24 | ntfy | .10 |
| `dns` | 172.20.5.0/24 | hickory-dns | .10 |

Cross-links: caddy ↔ auth, caddy ↔ vault, caddy ↔ ntfy, authelia ↔ proxy

### oci-apps (172.21.0.0/16)

| Network | Subnet | Containers | IPs |
|---------|--------|------------|-----|
| `c3` | 172.21.1.0/24 | c3-api, orchestrator | .10, .11 |
| `rig` | 172.21.2.0/24 | rig-agentic | .10 |
| `nocodb` | 172.21.3.0/24 | nocodb, nocodb-db | .10, .11 |
| `mattermost` | 172.21.4.0/24 | mattermost, mattermost-postgres, mattermost-bots | .10, .11, .12 |
| `crawlee` | 172.21.5.0/24 | crawlee_redis, crawlee_db, crawlee_minio, crawlee_scheduler | .10-.13 |
| `surrealdb` | 172.21.6.0/24 | surrealdb | .10 |
| `lgtm` | 172.21.7.0/24 | lgtm_grafana, lgtm_loki, lgtm_mimir, lgtm_tempo | .10-.13 |
| `photoprism` | 172.21.8.0/24 | photoprism_app, photoprism_mariadb, photoprism_rclone | .10-.12 |
| `gitea` | 172.21.9.0/24 | gitea | .10 |
| `codeserver` | 172.21.10.0/24 | code-server | .10 |
| `cloud-spec` | 172.21.11.0/24 | cloud-spec | .10 |
| `hedgedoc` | 172.21.12.0/24 | hedgedoc_app, hedgedoc_postgres | .10, .11 |
| `grist` | 172.21.13.0/24 | grist_app | .10 |
| `filebrowser` | 172.21.14.0/24 | filebrowser_app | .10 |
| `etherpad` | 172.21.15.0/24 | etherpad_app, etherpad_postgres | .10, .11 |
| `radicale` | 172.21.16.0/24 | radicale | .10 |
| `revealmd` | 172.21.17.0/24 | revealmd_app | .10 |

### oci-mail (172.22.0.0/16)

| Network | Subnet | Containers | IPs |
|---------|--------|------------|-----|
| `mailu` | 172.22.1.0/24 | mailu-front, mailu-resolver, mailu-admin, mailu-imap, mailu-smtp, mailu-antispam, mailu-webmail, mailu-db | .10-.17 |
| `syncthing` | 172.22.2.0/24 | syncthing | .10 |
| `radicale` | 172.22.3.0/24 | radicale | .10 |
| `dagu` | 172.22.4.0/24 | dagu | .10 |

Note: Mailu keeps its own network — it has complex internal dependencies between containers. No need to migrate to a shared network.

### oci-analytics (172.23.0.0/16)

| Network | Subnet | Containers | IPs |
|---------|--------|------------|-----|
| `matomo` | 172.23.1.0/24 | matomo, matomo-db | .10, .11 |
| `windmill` | 172.23.2.0/24 | windmill, windmill-db, windmill-worker | .10-.12 |

### Implementation

**New shared module**: `_shared/modules/docker-network.nix`

Parameterized module. Creates per-service Docker networks on activation from the `containerNetwork.networks` definition.

```nix
# Pseudocode
{ containerNetwork }:
activation.script = ''
  ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: net: ''
    docker network inspect ${name} >/dev/null 2>&1 || \
      docker network create ${name} --subnet ${net.subnet} --gateway ${net.gateway}
  '') containerNetwork.networks)}
'';
```

**Service flakes** reference network name + fixed `ipv4_address` per container. They no longer use `npm_default`.

---

## Step 3: dnsmasq as Systemd Service on Host

### Why host, not Docker container

| Docker container dnsmasq | Host systemd dnsmasq |
|--------------------------|---------------------|
| Circular: containers depend on it, but it IS a container | No dependency — always available, even before Docker starts |
| Dies on Docker restart → all containers lose DNS | Survives Docker restarts |
| Needs `infra` network to exist first (chicken-and-egg) | Listens on all bridge gateways directly |
| Extra container to manage, image to pull | Binary from nix, zero overhead |

### New shared module: `_shared/modules/dnsmasq.nix`

Parameterized module: `{ containerNetwork, vmName }:`

**What dnsmasq resolves**:
- Container names → fixed IPs (from `containerNetwork.containers`)
- Cross-VM service names → WireGuard IPs (from mesh topology)
- Everything else → upstream (Cloudflare 1.1.1.1 / Google 8.8.8.8)

**Listens on**: All Docker bridge gateway IPs for this VM (e.g. 172.20.1.1, 172.20.2.1, ...) + 127.0.0.1.
Does NOT listen on public IP or WG IP (Hickory DNS handles `.internal` zone on WG).

**Generated config files** (by home-manager activation):

```
/etc/dnsmasq.d/
├── containers.conf    # host-record=caddy,172.20.1.10
│                      # host-record=authelia,172.20.2.10
│                      # (auto-generated from containerNetwork.containers)
├── mesh.conf          # host-record=oci-apps,10.0.0.6
│                      # host-record=gcp-proxy,10.0.0.1
│                      # (auto-generated from wireguard topology)
└── upstream.conf      # server=1.1.1.1
                       # server=8.8.8.8
```

**Systemd service** (managed by home-manager activation, same pattern as firewall.nix):

```ini
[Unit]
Description=dnsmasq container DNS (${vmName})
After=network.target
Before=docker.service

[Service]
Type=simple
ExecStart=/path/to/dnsmasq --no-daemon --conf-dir=/etc/dnsmasq.d
Restart=always

[Install]
WantedBy=multi-user.target
```

**Every container** in docker-compose gets:
```yaml
dns: ["${gateway_ip_of_its_network}"]
```

Since dnsmasq listens on all bridge gateways, each container reaches it at its own gateway IP. No cross-network dependency.

### Listen address generation (from containerNetwork)

```nix
listenAddresses = lib.mapAttrsToList (_: net: net.gateway) containerNetwork.networks;
# Result: ["172.20.1.1" "172.20.2.1" "172.20.3.1" ...]
# dnsmasq --listen-address=172.20.1.1,172.20.2.1,...,127.0.0.1
```

---

## Step 4: busybox httpd on Every VM (WG mesh only)

### New shared module: `_shared/modules/web-server-busybox.nix`

Lightweight busybox httpd serving `~/` (home dir) on WG interface only.

**Purpose**: Quick file access across mesh (configs, logs, debug) without SSH.

**Config**:
```nix
{
  bindAddress = "10.0.0.X";   # WG IP only — NOT public
  port = 8080;
  root = "/home/${user}";
  enableDirectoryListing = true;
}
```

**Generates**:
- `/etc/systemd/system/httpd-home.service`
- Runs: `busybox httpd -f -p 10.0.0.X:8080 -h /home/user`
- Only accessible from WireGuard mesh (10.0.0.0/24)

**Note**: Different from existing `httpd.nix` which serves specific app dirs. This is a general-purpose home dir browser for ops.

---

## Step 5: Declarative Firewall DNAT Rules

### Update `_shared/modules/firewall.nix`

With fixed container IPs, we can now write deterministic DNAT rules. The current firewall.nix comment says "Port publishing works via docker-proxy (userland), no DNAT needed" — this is what breaks. We replace docker-proxy with explicit DNAT.

**New parameter**: `dnatRules` — auto-generated from `containerNetwork.containers` entries that have `ports`.

```nix
# firewall.nix signature becomes:
{ vmName, publicPorts ? [], containerNetwork ? null }:

# If containerNetwork is provided, auto-generate DNAT rules from containers with ports
dnatRules = lib.optionals (containerNetwork != null)
  (lib.concatLists (lib.mapAttrsToList (name: c:
    map (port: {
      proto = "tcp";
      dport = port;
      dest = "${c.ip}:${toString port}";
      desc = name;
    }) (c.ports or [])
  ) containerNetwork.containers));
```

**Generated iptables** (auto-derived from containerNetwork):
```bash
# NAT PREROUTING — auto-generated from containerNetwork.containers
iptables -t nat -A PREROUTING -p tcp --dport 80 -j DNAT --to-destination 172.20.1.10:80    # caddy
iptables -t nat -A PREROUTING -p tcp --dport 443 -j DNAT --to-destination 172.20.1.10:443  # caddy
iptables -t nat -A PREROUTING -p tcp --dport 9091 -j DNAT --to-destination 172.20.2.10:9091 # authelia

# FORWARD — allow traffic to all container subnets
iptables -A FORWARD -d 172.20.0.0/16 -j ACCEPT
```

No manual DNAT list needed — it's derived from the same `containerNetwork` that drives docker-compose and dnsmasq. **One definition, three consumers.**

---

## Step 6: Update Hickory DNS (optional enhancement)

Add container-level records to Hickory DNS for cross-VM container resolution:

```
; Container records (optional, dnsmasq handles local)
caddy.gcp-proxy.internal.    IN A 172.20.1.10
c3-api.oci-apps.internal.    IN A 172.21.1.10
```

**Lower priority** — dnsmasq handles local, and cross-VM access uses WG IPs + Caddy. But useful for direct container-to-container cross-VM communication.

---

## File Changes Summary

| File | Action | What |
|------|--------|------|
| `_shared/modules/docker-network.nix` | **NEW** | Creates per-service Docker networks with fixed subnets (parameterized) |
| `_shared/modules/dnsmasq.nix` | **NEW** | dnsmasq systemd service on host + config generation (parameterized) |
| `_shared/modules/web-server-busybox.nix` | **NEW** | busybox httpd serving ~/home on WG interface |
| `_shared/modules/firewall.nix` | **EDIT** | Add `containerNetwork` param, auto-generate DNAT + FORWARD from it |
| `_shared/modules/docker-service.nix` | **EDIT** | Keep `iptables: false` (confirmed correct) |
| `_shared/modules/shared-all.nix` | **NO CHANGE** | New modules are parameterized → imported explicitly per VM |
| `gcp-proxy/src/gcp-proxy.nix` | **EDIT** | Add `containerNetwork` definition (single source of truth) |
| `oci-apps/src/oci-apps.nix` | **EDIT** | Add `containerNetwork` definition |
| `oci-mail/src/oci-mail.nix` | **EDIT** | Add `containerNetwork` definition |
| `oci-analytics/src/oci-analytics.nix` | **EDIT** | Add `containerNetwork` definition |
| `oci-apps-2/src/oci-apps-2.nix` | **EDIT** | Add `containerNetwork` definition |
| `gcp-t4/src/gcp-t4.nix` | **EDIT** | Add `containerNetwork` definition |
| Every service `flake.nix` | **EDIT** | Replace `npm_default` → service network + `ipv4_address` + `dns: [gateway]` |

---

## Execution Order

1. **Create modules** (docker-network.nix, dnsmasq.nix, web-server-busybox.nix)
2. **Update firewall.nix** — add `containerNetwork` param, auto-generate DNAT
3. **Add `containerNetwork` to gcp-proxy.nix** (test VM first)
4. **Update gcp-proxy service flakes** (caddy, authelia, vaultwarden, ntfy, hickory-dns) — one at a time
5. **Push home-manager for gcp-proxy only** → GHA deploys
6. **Ship gcp-proxy services** (`build.sh ship` per service)
7. **Verify gcp-proxy**: containers resolve each other, ports forward, WG mesh works, public access works
8. **Repeat for each VM**: oci-apps, oci-mail, oci-analytics, oci-apps-2, gcp-t4

**Rule: one VM at a time. Never push all VMs simultaneously.**

---

## Risk Notes

- **Migration**: Existing containers on `npm_default` need recreation on new networks — brief downtime per service
- **Mailu**: Keeps its own network (172.22.1.0/24) — complex internal deps, no reason to change its internal networking
- **dnsmasq binary**: Use nix `pkgs.dnsmasq` — guaranteed available on all VMs via home-manager, no Docker image needed
- **Port conflicts**: dnsmasq listens on Docker bridge gateways only (172.X.Y.1), NOT on 10.0.0.X or public IP — no conflict with Hickory DNS
- **busybox httpd**: Serving ~/home is a security consideration — WG-only binding mitigates this
- **Cross-network links**: Containers needing cross-service access (e.g. caddy → authelia) must be attached to both networks in docker-compose. This is explicit and auditable.
- **Rollback**: If a VM breaks, revert its `.nix` config + re-ship services. Each VM is independent.
