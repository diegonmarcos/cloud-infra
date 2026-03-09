# Plan: Docker DNS + Fixed IPs + Declarative Networking

**Date**: 2026-03-09
**Updated**: 2026-03-09 (v6 — parser adjustments for gen-topology/gen-configs)
**Root Cause**: Docker with `iptables: false` loses container DNS resolution and port forwarding. Docker engine restart/reboot wipes DNAT rules. Setting `iptables: true` conflicts with our declarative firewall.nix.

**Goal**: Full declarative control — we own DNS, IPs, firewall rules, auth routing. Docker only runs containers.

**Design Principles**:
1. `iptables: false` stays — we own all networking, not Docker
2. **Single source of truth** — `meshTopology` (shared) + `containerNetwork` (per-VM) + `build.json` auth metadata (per-service)
3. **Isolate by trust boundary** — separate networks only where a service has its own database to protect. Standalone services share a network.
4. **No circular dependencies** — dnsmasq runs on host (systemd), not inside Docker
5. **Right-sized subnets** — /27 for shared networks (up to 30 containers), /28 for service networks (up to 14 containers)
6. **Caddy is the bouncer** — all cross-VM traffic goes through Caddy. No direct container-to-container routing across VMs.
7. **Each service owns its auth** — auth policy declared in service `build.json`, Caddy + Authelia configs auto-generated from it

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
| WG topology | Hardcoded in wireguard.nix | Duplicated in dnsmasq mesh.conf, firewall WG rules are blanket accept |
| Auth config | Manually synced across 3 files (Authelia ACL, Caddy forward_auth, introspect-proxy) | Add service = edit 3 files, forget one = broken or open auth |
| Caddy upstreams | Hardcoded WG IPs (10.0.0.X:port) | Must manually update when IPs change |
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
                                   trust-zone  trust-zone trust-zone
                                   networks    networks    networks
```

Key design decisions:
- dnsmasq is a **systemd service on the host**, not a Docker container
- Networks grouped by **trust boundary** (has-own-DB = isolated, standalone = shared)
- **Three data sources**: `meshTopology` (shared) + `containerNetwork` (per-VM) + `build.json` auth (per-service)
- Caddy routes, Authelia ACL, introspect-proxy config all **auto-generated** from service `build.json`
- /27 for shared networks, /28 for isolated service networks
- All cross-VM traffic through Caddy — WG carries it, Caddy gates it

---

## Data Architecture: Three Sources of Truth

### 1. `mesh-topology.nix` — shared across all VMs

Lives at `_shared/mesh-topology.nix`. Defines the WireGuard mesh: peers, WG IPs, endpoints.

Consumed by: wireguard.nix, dnsmasq.nix (mesh.conf), firewall.nix (WG FORWARD), **Caddy flake (upstream IPs)**.

```nix
# _shared/mesh-topology.nix
{
  peers = {
    gcp-proxy     = { wgIp = "10.0.0.1";  endpoint = "35.226.147.64:51820";  role = "hub"; };
    oci-apps      = { wgIp = "10.0.0.6";  endpoint = "82.70.229.129:51820";  role = "spoke"; };
    oci-mail      = { wgIp = "10.0.0.3";  endpoint = "130.110.251.193:51820"; role = "spoke"; };
    oci-analytics = { wgIp = "10.0.0.4";  endpoint = "129.151.228.66:51820"; role = "spoke"; };
    oci-apps-2    = { wgIp = "10.0.0.7";  endpoint = "144.24.196.72:51820";  role = "spoke"; };
    gcp-t4        = { wgIp = "10.0.0.8";  endpoint = "...";                  role = "spoke"; };
  };

  clients = {
    surface = { wgIp = "10.0.0.10"; };
    termux  = { wgIp = "10.0.0.11"; };
  };

  wgSubnet = "10.0.0.0/24";
  wgPort = 51820;
}
```

**Replaces**: hardcoded peer list in current `wireguard.nix` + hardcoded WG IPs in Caddy flake.

### 2. `containerNetwork` — per-VM in each `.nix` file

Defined in each VM's config (e.g. `gcp-proxy.nix`). Contains networks, container IPs, ports.

Consumed by: docker-network.nix, dnsmasq.nix (containers.conf), firewall.nix (DNAT rules).

```nix
# In gcp-proxy.nix
containerNetwork = { ... };  # see Step 1 below
```

### 3. `build.json` auth metadata — per-service

Each service declares its auth requirements in its existing `build.json`. This is where auth lives today (conceptually) — it just wasn't formalized. Now it is.

Consumed by: Caddy flake (routes, forward_auth, introspect), Authelia flake (ACL), OIDC audience list.

```jsonc
// Example: a_solutions/aa-sui_tools-mailu/build.json
{
  "name": "mailu",
  "description": "Email server",
  "deploy": {
    "host": "oci-mail",
    "remote_path": "/opt/containers/mailu"
  },
  "auth": {
    "domain": "mail.diegonmarcos.com",
    "policy": "two_factor",
    "bearer": true,
    "tls_skip": true
  }
}
```

```jsonc
// Example: bb-sec_vaultwarden/build.json
{
  "name": "vaultwarden",
  "description": "Password manager",
  "deploy": {
    "host": "gcp-proxy",
    "remote_path": "/opt/containers/vaultwarden"
  },
  "auth": {
    "domain": "vault.diegonmarcos.com",
    "policy": "two_factor",
    "bypass": ["^/api.*", "^/identity.*", "^/icons.*", "^/notifications.*", "^/attachments.*"],
    "admin_paths": ["^/admin.*"]
  }
}
```

```jsonc
// Example: bc-obs_matomo/build.json
{
  "name": "matomo",
  "description": "Web analytics",
  "deploy": {
    "host": "oci-analytics",
    "remote_path": "/opt/containers/matomo"
  },
  "auth": {
    "domain": "analytics.diegonmarcos.com",
    "policy": "two_factor",
    "bearer": true,
    "public": ["/matomo.js", "/matomo.php", "/js/*"]
  }
}
```

```jsonc
// Example: bb-sec_mcp-server-skills/build.json
{
  "name": "c3-api",
  "description": "Cloud control center",
  "deploy": {
    "host": "oci-apps",
    "remote_path": "/opt/containers/c3-api"
  },
  "auth": {
    "domain": "api.diegonmarcos.com",
    "path_prefix": "/c3-api",
    "policy": "two_factor",
    "bearer": true,
    "public": ["/c3-api/docs"]
  }
}
```

### `auth` schema (in build.json)

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `domain` | string | yes | Public domain for this service |
| `policy` | `"bypass"` \| `"one_factor"` \| `"two_factor"` | yes | Authelia access policy |
| `bearer` | bool | no | Accept bearer tokens (introspect-proxy). Default: false |
| `public` | string[] | no | Paths that bypass auth entirely (e.g. matomo.js, API docs) |
| `bypass` | string[] | no | Regex paths that bypass auth (e.g. Vaultwarden API) |
| `admin_paths` | string[] | no | Regex paths requiring `two_factor` even if default policy is lower |
| `path_prefix` | string | no | Route prefix (e.g. `/c3-api` for shared domains like `api.diegonmarcos.com`) |
| `tls_skip` | bool | no | Skip TLS verification on upstream. Default: false |
| `websocket` | string | no | WebSocket path (e.g. `/api/v4/websocket` for Mattermost) |

### How all three flow into modules

```
mesh-topology.nix (shared)     containerNetwork (per-VM)     build.json auth (per-service)
        │                               │                              │
        ├──→ wireguard.nix              ├──→ docker-network.nix        ├──→ Caddy flake
        │    (peers, AllowedIPs)        │    (create networks)         │    (routes, forward_auth,
        │                               │                              │     introspect, public paths,
        ├──→ dnsmasq.nix               ├──→ dnsmasq.nix               │     upstream IPs from meshTopology)
        │    (mesh.conf)                │    (containers.conf)         │
        │                               │                              ├──→ Authelia flake
        ├──→ firewall.nix              ├──→ firewall.nix               │    (ACL rules, bypass paths,
        │    (WG FORWARD)               │    (DNAT, container FORWARD) │     admin_paths)
        │                               │                              │
        ├──→ Caddy flake               │                              └──→ OIDC audience list
        │    (upstream WG IPs)          │                                   (services with bearer=true)
        │                               │
        └──→ busybox httpd              │
             (bind address)             │
```

### VM config import pattern

```nix
# gcp-proxy/src/gcp-proxy.nix
let
  meshTopology = import ./mesh-topology.nix;
  containerNetwork = { ... };  # defined here — this VM's containers
in {
  imports = [
    (import ./wireguard.nix { vmName = "gcp-proxy"; inherit meshTopology; })
    (import ./modules/firewall.nix { vmName = "gcp-proxy"; inherit meshTopology containerNetwork; publicPorts = [ ... ]; })
    (import ./modules/dnsmasq.nix { vmName = "gcp-proxy"; inherit meshTopology containerNetwork; })
    (import ./modules/docker-network.nix { inherit containerNetwork; })
    (import ./modules/web-server-busybox.nix { vmName = "gcp-proxy"; inherit meshTopology; })
    ./modules/shared-all.nix
  ];
}
```

Adding a new VM = add it to `mesh-topology.nix` + create its `.nix` with `containerNetwork`. All modules pick it up automatically.

Adding a new service = add `auth` block to its `build.json` + run Caddy/Authelia build. Routes, ACL, and introspect config auto-generated.

---

## Auth Config Generation (Caddy + Authelia + introspect-proxy)

### How Caddy builds its config

The Caddy flake (`bb-sec_caddy/src/flake.nix`) scans all `build.json` files across `a_solutions/*/build.json` at build time. For each service with an `auth` block, it generates:

1. **Caddyfile route** — `domain { reverse_proxy upstream:port }`
2. **Auth handler** — based on `auth.bearer`:
   - `bearer = false` → cookie-only: `forward_auth authelia:9091`
   - `bearer = true` → dual-auth: `@bearer header Authorization Bearer*` + introspect-proxy fallback
3. **Public paths** — `auth.public` paths get `handle` blocks without forward_auth
4. **Bypass paths** — `auth.bypass` regex paths get `handle` blocks without auth
5. **Upstream IP** — resolved from `meshTopology.peers[deploy.host].wgIp` + service port (no hardcoded IPs)

```nix
# Pseudocode in Caddy flake.nix
let
  # Read all build.json files
  serviceConfigs = builtins.map (dir:
    builtins.fromJSON (builtins.readFile "${dir}/build.json")
  ) (builtins.attrNames (builtins.readDir ../..));  # scan a_solutions/*/

  # Filter services with auth blocks
  authedServices = builtins.filter (s: s ? auth) serviceConfigs;

  # Resolve upstream from meshTopology
  upstreamFor = svc:
    let vm = meshTopology.peers.${svc.deploy.host};
    in "${vm.wgIp}:${toString svc.port}";
in
  # Generate Caddyfile blocks for each service
  ...
```

### How Authelia builds its ACL

The Authelia flake (`bb-sec_authelia/src/flake.nix`) reads the same `build.json` files and generates:

```yaml
access_control:
  default_policy: two_factor
  rules:
    # Auto-generated from build.json auth blocks:

    # Vaultwarden — bypass API, admin requires 2FA
    - domain: vault.diegonmarcos.com
      resources: ["^/api.*", "^/identity.*", "^/icons.*"]
      policy: bypass
    - domain: vault.diegonmarcos.com
      resources: ["^/admin.*"]
      policy: two_factor
    - domain: vault.diegonmarcos.com
      policy: bypass

    # Matomo — public tracking paths
    - domain: analytics.diegonmarcos.com
      resources: ["/matomo.js", "/matomo.php", "/js/*"]
      policy: bypass
    - domain: analytics.diegonmarcos.com
      policy: two_factor

    # NocoDB — API bypass
    - domain: db.diegonmarcos.com
      resources: ["^/api/.*"]
      policy: bypass
    - domain: db.diegonmarcos.com
      policy: two_factor

    # All others — use their declared policy
    - domain: "*.diegonmarcos.com"
      policy: two_factor
```

### How OIDC audience list is generated

Services with `bearer = true` automatically get added to the OIDC client's `audience` list:

```yaml
clients:
  - client_id: cli
    audience:
      # Auto-generated from build.json where bearer=true:
      - https://analytics.diegonmarcos.com/
      - https://api.diegonmarcos.com/
      - https://cal.diegonmarcos.com/
      - https://db.diegonmarcos.com/
      - https://mail.diegonmarcos.com/
      - https://photos.diegonmarcos.com/
      - https://rss.diegonmarcos.com/
      - https://sync.diegonmarcos.com/
```

### What this replaces

| Before | After |
|--------|-------|
| Caddy Caddyfile: manually add route + forward_auth per service | Auto-generated from `build.json` auth blocks |
| Authelia ACL: manually add domain + policy per service | Auto-generated from `build.json` auth blocks |
| introspect-proxy: manually decide which routes get bearer | Auto: `bearer = true` in `build.json` → route gets introspect |
| OIDC audience: manually list domains | Auto: services with `bearer = true` added to audience |
| Caddy upstream IPs: hardcoded `10.0.0.X:port` | Resolved from `meshTopology.peers[deploy.host].wgIp` |
| Adding a service: edit Caddy + Authelia + introspect + OIDC | Add `auth` to `build.json`, rebuild Caddy + Authelia |

---

## Network Design: Trust Boundary Isolation

### Why not per-service networks?

Per-service networks (v2) gave gcp-proxy 5 networks and oci-apps 17 networks. Problems:
- Standalone services (grist, filebrowser, revealmd, etc.) with no private database gain nothing from isolation — they're all equally exposed via Caddy
- 17 networks = 17 bridge interfaces + veth pairs + cross-network links everywhere
- Cross-network links (caddy ↔ auth, caddy ↔ vault, caddy ↔ ntfy) turn "isolated" networks into a de facto flat network with extra complexity

### Why not one flat network?

One network per VM (v1) means a compromised container can reach every database on the VM. The real threat is: app container → other service's database.

### Trust boundary rule

**Isolate services that have their own database.** Their app + DB containers share a private network. Everything else goes on a shared `apps` network.

```
                    ┌─────────────────────────────────────────────┐
                    │              apps (shared /27)              │
                    │  caddy, authelia, c3-api, gitea, ntfy, ... │
                    └─────────────────────────────────────────────┘
                         ↑ can't reach ↓           ↑ can't reach ↓
    ┌──────────────────────┐  ┌──────────────────────┐  ┌──────────────────────┐
    │  mattermost (/28)    │  │  nocodb (/28)        │  │  photoprism (/28)    │
    │  app + postgres      │  │  app + postgres      │  │  app + mariadb       │
    └──────────────────────┘  └──────────────────────┘  └──────────────────────┘
```

Services on the `apps` network can reach each other (they're all Caddy upstreams anyway), but they **cannot** reach mattermost-postgres, nocodb-db, or photoprism-mariadb.

Services with their own DB get attached to **both** their private network and `apps` (for Caddy/DNS/mesh access). Their DB containers are on the private network **only**.

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
  networks = {
    apps       = { subnet = "172.20.0.0/27";  gateway = "172.20.0.1"; };   # shared — up to 30 containers
    mattermost = { subnet = "172.20.0.32/28"; gateway = "172.20.0.33"; };  # isolated — app + db
    nocodb     = { subnet = "172.20.0.48/28"; gateway = "172.20.0.49"; };  # isolated — app + db
  };

  containers = {
    # Shared network — standalone services (no private DB to protect)
    caddy            = { ip = "172.20.0.2";  network = "apps"; ports = [ 80 443 ]; };
    authelia         = { ip = "172.20.0.3";  network = "apps"; ports = [ 9091 ]; };
    redis            = { ip = "172.20.0.4";  network = "apps"; };
    vaultwarden      = { ip = "172.20.0.5";  network = "apps"; ports = [ 80 ]; };
    ntfy             = { ip = "172.20.0.6";  network = "apps"; ports = [ 8090 ]; };
    hickory-dns      = { ip = "172.20.0.7";  network = "apps"; ports = [ 53 ]; };
    introspect-proxy = { ip = "172.20.0.8";  network = "apps"; };

    # Isolated network — app on both networks, DB on private only
    mattermost          = { ip = "172.20.0.34"; network = "mattermost"; also = [ "apps" ]; ports = [ 8065 ]; };
    mattermost-postgres = { ip = "172.20.0.35"; network = "mattermost"; };  # DB — private only
    nocodb              = { ip = "172.20.0.50"; network = "nocodb"; also = [ "apps" ]; ports = [ 8085 ]; };
    nocodb-db           = { ip = "172.20.0.51"; network = "nocodb"; };  # DB — private only
  };
};
```

`also = [ "apps" ]` — app containers that need Caddy/DNS access get attached to the shared network too. Their DB containers stay isolated.

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

## Step 2: Docker Networks with Fixed Subnets

### Subnet Allocation Scheme

Each VM gets a /16 block. Shared network gets /27 (first 32 IPs). Isolated service networks get /28 (16 IPs each), packed sequentially after the shared block.

| VM | Block | Shared (/27) | Isolated (/28s) |
|----|-------|-------------|-----------------|
| gcp-proxy | 172.20.0.0/16 | 172.20.0.0/27 | 172.20.0.32/28, .48/28 |
| oci-apps | 172.21.0.0/16 | 172.21.0.0/27 | 172.21.0.32/28, .48/28, .64/28, .80/28, .96/28, .112/28 |
| oci-mail | 172.22.0.0/16 | 172.22.0.0/27 | 172.22.0.32/28 |
| oci-analytics | 172.23.0.0/16 | 172.23.0.0/27 | 172.23.0.32/28, .48/28 |
| oci-apps-2 | 172.24.0.0/16 | 172.24.0.0/27 | — |
| gcp-t4 | 172.25.0.0/16 | 172.25.0.0/27 | — |

### gcp-proxy (172.20.0.0/16) — 2 networks

| Network | Subnet | Containers | IPs |
|---------|--------|------------|-----|
| `apps` | 172.20.0.0/27 | caddy, introspect-proxy, authelia, redis, vaultwarden, ntfy | .2-.7 |
| `dns` | 172.20.0.32/28 | hickory-dns | .34 |

Why `dns` is isolated: hickory-dns handles recursive resolution on UDP 53, a different trust level than HTTP services. Caddy doesn't need to reach it — it resolves via dnsmasq on the host.

### oci-apps (172.21.0.0/16) — 7 networks

| Network | Subnet | Containers | IPs |
|---------|--------|------------|-----|
| `apps` | 172.21.0.0/27 | c3-api, orchestrator, rig-agentic, surrealdb, gitea, code-server, cloud-spec, grist, filebrowser, radicale, revealmd, lgtm_grafana, lgtm_loki, lgtm_mimir, lgtm_tempo | .2-.16 |
| `mattermost` | 172.21.0.32/28 | mattermost (+apps), mattermost-postgres, mattermost-bots | .34-.36 |
| `nocodb` | 172.21.0.48/28 | nocodb (+apps), nocodb-db | .50-.51 |
| `crawlee` | 172.21.0.64/28 | crawlee_scheduler (+apps), crawlee_redis, crawlee_db, crawlee_minio | .66-.69 |
| `photoprism` | 172.21.0.80/28 | photoprism_app (+apps), photoprism_mariadb, photoprism_rclone | .82-.84 |
| `hedgedoc` | 172.21.0.96/28 | hedgedoc_app (+apps), hedgedoc_postgres | .98-.99 |
| `etherpad` | 172.21.0.112/28 | etherpad_app (+apps), etherpad_postgres | .114-.115 |

`(+apps)` = container attached to both its private network and the shared `apps` network.

LGTM stack goes on `apps` — Grafana/Loki/Prometheus are monitoring tools, not user-data stores. They're all Caddy upstreams.

### oci-mail (172.22.0.0/16) — 2 networks

| Network | Subnet | Containers | IPs |
|---------|--------|------------|-----|
| `apps` | 172.22.0.0/27 | syncthing, radicale, dagu | .2-.4 |
| `mailu` | 172.22.0.32/28 | mailu-front, mailu-resolver, mailu-admin, mailu-imap, mailu-smtp, mailu-antispam, mailu-webmail, mailu-db | .34-.41 |

Mailu stays isolated — 8 tightly-coupled containers with their own DB. mailu-front gets `also = ["apps"]` for Caddy access.

### oci-analytics (172.23.0.0/16) — 3 networks

| Network | Subnet | Containers | IPs |
|---------|--------|------------|-----|
| `apps` | 172.23.0.0/27 | (empty for now, future standalone services) | — |
| `matomo` | 172.23.0.32/28 | matomo (+apps), matomo-db | .34-.35 |
| `windmill` | 172.23.0.48/28 | windmill (+apps), windmill-db, windmill-worker | .50-.52 |

Both services have their own DB → isolated. App containers bridge to `apps` for DNS/mesh.

### oci-apps-2 (172.24.0.0/16) — 1 network

| Network | Subnet | Containers | IPs |
|---------|--------|------------|-----|
| `apps` | 172.24.0.0/27 | ollama-arm | .2 |

Single service, no DB isolation needed.

### gcp-t4 (172.25.0.0/16) — 1 network

| Network | Subnet | Containers | IPs |
|---------|--------|------------|-----|
| `apps` | 172.25.0.0/27 | ollama | .2 |

Single service, no DB isolation needed.

### Network count comparison

| VM | v1 (flat) | v2 (per-service) | v3+ (trust boundary) |
|----|-----------|------------------|---------------------|
| gcp-proxy | 1 | 5 | 2 |
| oci-apps | 1 | 17 | 7 |
| oci-mail | 1 | 4 | 2 |
| oci-analytics | 1 | 2 | 3 |
| oci-apps-2 | 1 | 1 | 1 |
| gcp-t4 | 1 | 1 | 1 |
| **Total** | **6** | **30** | **16** |

### Implementation

**New shared module**: `_shared/modules/docker-network.nix`

Parameterized module. Creates Docker networks on activation from `containerNetwork.networks`.

```nix
{ containerNetwork }:
activation.script = ''
  ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: net: ''
    docker network inspect ${name} >/dev/null 2>&1 || \
      docker network create ${name} --subnet ${net.subnet} --gateway ${net.gateway}
  '') containerNetwork.networks)}
'';
```

**Service flakes** reference network name + fixed `ipv4_address` per container. Containers with `also` get multiple `networks:` entries in docker-compose. They no longer use `npm_default`.

---

## Step 3: dnsmasq as Systemd Service on Host

### Why host, not Docker container

| Docker container dnsmasq | Host systemd dnsmasq |
|--------------------------|---------------------|
| Circular: containers depend on it, but it IS a container | No dependency — always available, even before Docker starts |
| Dies on Docker restart → all containers lose DNS | Survives Docker restarts |
| Needs network to exist first (chicken-and-egg) | Listens on all bridge gateways directly |
| Extra container to manage, image to pull | Binary from nix, zero overhead |

### New shared module: `_shared/modules/dnsmasq.nix`

Parameterized module: `{ containerNetwork, meshTopology, vmName }:`

**What dnsmasq resolves**:
- Container names → fixed IPs (from `containerNetwork.containers`)
- Cross-VM service names → WireGuard IPs (from `meshTopology.peers`)
- Everything else → upstream (Cloudflare 1.1.1.1 / Google 8.8.8.8)

**Listens on**: All Docker bridge gateway IPs for this VM + 127.0.0.1.
Does NOT listen on public IP or WG IP (Hickory DNS handles `.internal` zone on WG).

**Generated config files** (by home-manager activation):

```
/etc/dnsmasq.d/
├── containers.conf    # host-record=caddy,172.20.0.2
│                      # host-record=authelia,172.20.0.3
│                      # (auto-generated from containerNetwork.containers)
├── mesh.conf          # host-record=oci-apps,10.0.0.6
│                      # host-record=gcp-proxy,10.0.0.1
│                      # (auto-generated from meshTopology.peers)
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
# Result: ["172.20.0.1" "172.20.0.33" ...]
# dnsmasq --listen-address=172.20.0.1,172.20.0.33,...,127.0.0.1
```

---

## Step 4: WireGuard — Shared Topology + Tighter Firewall

### What changes

| Before | After |
|--------|-------|
| Peer list hardcoded in wireguard.nix | Reads from `meshTopology.peers` |
| dnsmasq mesh.conf manually maintained | Auto-generated from `meshTopology.peers` |
| `iptables -A FORWARD -i wg0 -j ACCEPT` (blanket) | Only allow WG traffic to this VM's container subnets + WG mesh |
| Adding a VM = edit wireguard.nix + dnsmasq + firewall | Add to `mesh-topology.nix`, all modules update |

### wireguard.nix reads meshTopology

```nix
# wireguard.nix signature becomes:
{ vmName, meshTopology }:

# Generate [Peer] sections from meshTopology.peers
# AllowedIPs = peer's wgIp/32 only (no container subnets — Caddy is the bouncer)
peers = lib.mapAttrsToList (name: peer: {
  PublicKey = "...";  # still from secrets/generated on-VM
  AllowedIPs = "${peer.wgIp}/32";
  Endpoint = peer.endpoint;
}) (lib.filterAttrs (n: _: n != vmName) meshTopology.peers);
```

Cross-VM container traffic still goes through Caddy (WG IP → Caddy port → upstream). No container subnet routing through WG.

### Tighter WG FORWARD rules in firewall.nix

```nix
# firewall.nix reads meshTopology for WG rules
{ vmName, publicPorts ? [], containerNetwork ? null, meshTopology ? null }:

# Before (blanket):
# iptables -A FORWARD -i wg0 -j ACCEPT
# iptables -A FORWARD -o wg0 -j ACCEPT

# After (scoped):
wgForwardRules = lib.optionals (meshTopology != null) [
  # Allow WG traffic to this VM's container subnets only
  (lib.concatStringsSep "\n" (lib.mapAttrsToList (_: net:
    "iptables -A FORWARD -i wg0 -d ${net.subnet} -j ACCEPT"
  ) containerNetwork.networks))
  # Allow WG mesh itself
  "iptables -A FORWARD -i wg0 -d ${meshTopology.wgSubnet} -j ACCEPT"
  # Allow return traffic
  "iptables -A FORWARD -o wg0 -m state --state ESTABLISHED,RELATED -j ACCEPT"
];
```

A compromised WG peer can only reach container subnets on this VM that are explicitly defined — not arbitrary host IPs.

---

## Step 5: busybox httpd on Every VM (WG mesh only)

### New shared module: `_shared/modules/web-server-busybox.nix`

Parameterized module: `{ meshTopology, vmName }:`

Reads WG IP from `meshTopology.peers.${vmName}.wgIp` — no hardcoded IPs.

**Purpose**: Quick file access across mesh (configs, logs, debug) without SSH.

**Config**:
```nix
{
  bindAddress = meshTopology.peers.${vmName}.wgIp;  # e.g. "10.0.0.1" — WG only
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

## Step 6: Declarative Firewall DNAT Rules

### Update `_shared/modules/firewall.nix`

With fixed container IPs, we can now write deterministic DNAT rules. The current firewall.nix comment says "Port publishing works via docker-proxy (userland), no DNAT needed" — this is what breaks. We replace docker-proxy with explicit DNAT.

**New parameters**: `containerNetwork` + `meshTopology` — DNAT rules auto-generated from containers with `ports`, WG FORWARD rules scoped from mesh topology.

```nix
# firewall.nix signature becomes:
{ vmName, publicPorts ? [], containerNetwork ? null, meshTopology ? null }:

# Auto-generate DNAT rules from containers with ports
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

**Generated iptables** (auto-derived from containerNetwork + meshTopology):
```bash
# NAT PREROUTING — auto-generated from containerNetwork.containers
iptables -t nat -A PREROUTING -p tcp --dport 80 -j DNAT --to-destination 172.20.0.2:80    # caddy
iptables -t nat -A PREROUTING -p tcp --dport 443 -j DNAT --to-destination 172.20.0.2:443  # caddy
iptables -t nat -A PREROUTING -p tcp --dport 9091 -j DNAT --to-destination 172.20.0.3:9091 # authelia

# FORWARD — container subnets (from containerNetwork.networks)
iptables -A FORWARD -d 172.20.0.0/27 -j ACCEPT    # apps
iptables -A FORWARD -d 172.20.0.32/28 -j ACCEPT   # dns

# FORWARD — WG scoped (from meshTopology, replaces blanket -i wg0 -j ACCEPT)
iptables -A FORWARD -i wg0 -d 172.20.0.0/27 -j ACCEPT    # WG → apps containers
iptables -A FORWARD -i wg0 -d 172.20.0.32/28 -j ACCEPT   # WG → dns containers
iptables -A FORWARD -i wg0 -d 10.0.0.0/24 -j ACCEPT      # WG → WG mesh
iptables -A FORWARD -o wg0 -m state --state ESTABLISHED,RELATED -j ACCEPT
```

No manual rules needed — all derived from `containerNetwork` + `meshTopology`. **Three definitions, seven consumers** (docker-compose, dnsmasq, firewall, wireguard, caddy, authelia, introspect-proxy).

---

## Step 7: Update Hickory DNS (optional enhancement)

Add container-level records to Hickory DNS for cross-VM container resolution:

```
; Container records (optional, dnsmasq handles local)
caddy.gcp-proxy.internal.    IN A 172.20.0.2
c3-api.oci-apps.internal.    IN A 172.21.0.2
```

**Lower priority** — dnsmasq handles local, and cross-VM access uses WG IPs + Caddy. But useful for direct container-to-container cross-VM communication.

---

## Step 8: C3 Parser Adjustments (gen-topology + gen-configs)

### Current parser architecture

`build.sh config` runs `gen-topology.ts` + `gen-configs.ts` which **reverse-engineer intent from output files** — regex-parsing Caddyfiles, docker-compose.yml, wireguard.nix, SSH config, firewall.nix. This works but is fragile (regex breaks on format changes) and redundant once intent is declared upfront.

### After the plan: parsers read declarations, not generated output

```
BEFORE: output files ──regex──→ parsers ──→ topology/configs JSON
AFTER:  declarations  ──read──→ parsers ──→ topology/configs JSON
                                    ↕ compare (drift detection)
        output files  ──regex──→ verification parsers
```

### Parser change matrix

| Parser | Current source | New source | Action |
|--------|---------------|------------|--------|
| `ssh-config.ts` | `~/.ssh/config` | `mesh-topology.nix` | **Replace** — all VM IPs, aliases, WG IPs are in meshTopology |
| `wireguard.ts` (peers) | Regex-parse nix syntax | `mesh-topology.nix` | **Replace** — simple structured read, no brace-matching regex |
| `wireguard.ts` (firewall) | Regex-parse iptables from nix | `containerNetwork` + `meshTopology` | **Replace** — firewall rules are derived from data, not reverse-parsed |
| `compose.ts` | Parse `dist/docker-compose.yml` | Keep + supplement from `containerNetwork` | **Adjust** — still parse compose for container names/images, but IPs/ports/networks come from `containerNetwork` |
| `build-json.ts` | `a_solutions/*/build.json` | Same + new `auth` block | **Extend** — add parsing of `auth` field (domain, policy, bearer, public, bypass, admin_paths, path_prefix, tls_skip, websocket) |
| `caddyfile.ts` | Regex-parse `dist/Caddyfile` | `build.json` auth blocks | **Repurpose** — primary data from `build.json` auth; keep parser as drift verifier |
| `authelia.ts` | Parse `dist/configuration.yml.tpl` | `build.json` auth blocks | **Repurpose** — primary data from `build.json` auth; keep parser as drift verifier |
| `terraform.ts` | Parse `main.tf` HCL | No change | **Keep** — VM specs (CPU/RAM/shape/storage) not in new data structures |
| `dns.ts` | Parse zone files | No change | **Keep** |
| `ntfy.ts` | Parse flake.nix + compose | No change | **Keep** |
| `mailu.ts` | Parse env + setup scripts | No change | **Keep** |

### New parser: `mesh-topology.ts`

Replaces `ssh-config.ts` + WG parts of `wireguard.ts`. Reads `mesh-topology.nix` (or a JSON export of it).

```typescript
// parsers/mesh-topology.ts
export function parseMeshTopology(): MeshTopology {
  // Option A: read mesh-topology.nix and parse nix attrset (simple flat structure)
  // Option B: gen-topology.ts exports mesh-topology.nix as JSON at build time
  //           (avoids nix parsing in TypeScript entirely)
  // Option B is cleaner — mesh-topology.nix is simple enough to also output as JSON
}
```

**Recommendation**: Option B — add a build step that exports `mesh-topology.nix` as `mesh-topology.json`. The nix file is the source of truth (used by home-manager), the JSON is a derived artifact for TypeScript consumers. Generated by `build.sh config` before running gen-topology.ts.

```bash
# In build.sh cmd_config():
nix eval --json -f "$HM_DIR/_shared/mesh-topology.nix" > "$REPO_ROOT/mesh-topology.json"
```

### New parser: `container-network.ts`

Reads `containerNetwork` definitions from VM nix configs. Same approach — export as JSON per VM.

```bash
# In build.sh cmd_config():
for vm_dir in "$HM_DIR"/*/src/*.nix; do
  # Extract containerNetwork attrset → JSON
  nix eval --json -f "$vm_dir" containerNetwork > "$REPO_ROOT/.cache/container-network-${vm}.json" 2>/dev/null || true
done
```

Or simpler: each VM's home-manager activation writes its `containerNetwork` as JSON to a known path on the VM, and `gen-topology.ts` reads it via SSH (for live topology) or from the nix source (for declared topology).

### Drift detection: caddyfile.ts + authelia.ts become verifiers

Instead of being primary data sources, these parsers become **drift detectors** in `gen-configs.ts`:

```typescript
// In gen-configs.ts:
const declaredRoutes = buildJsonAuth.map(svc => ({
  domain: svc.auth.domain,
  policy: svc.auth.policy,
  bearer: svc.auth.bearer ?? false,
  public: svc.auth.public ?? [],
}));

const deployedRoutes = parseCaddyfile();  // still regex-parses actual Caddyfile
const deployedACL = parseAuthelia();       // still parses actual Authelia config

// Compare declared vs deployed
const routeDrift = diffRoutes(declaredRoutes, deployedRoutes);
const aclDrift = diffACL(declaredRoutes, deployedACL);

// Output drift warnings in cloud-configs.json
configs.drift = {
  caddy: routeDrift,    // e.g. "route for photos.diegonmarcos.com declared but not in Caddyfile"
  authelia: aclDrift,   // e.g. "ACL for db.diegonmarcos.com differs: declared=two_factor, deployed=bypass"
};
```

This catches:
- Service added `auth` to `build.json` but Caddy not rebuilt yet
- Someone manually edited Caddyfile/Authelia without updating `build.json`
- Policy mismatch (declared two_factor but deployed one_factor)
- Missing routes (declared but not deployed, or deployed but not declared)

### gen-topology.ts changes

| Section | Before | After |
|---------|--------|-------|
| VM discovery | Parse SSH config + merge existing | Read `mesh-topology.json` for IPs/aliases, merge Terraform for specs |
| WireGuard mesh | Regex-parse wireguard.nix | Read `mesh-topology.json` directly |
| Container aggregation | Parse each service's `dist/docker-compose.yml` | Parse compose for images/names + supplement IPs/ports/networks from `containerNetwork` JSON |
| Firewall rules | Regex-parse iptables from nix | Report declared rules from `containerNetwork` (DNAT) + `meshTopology` (WG FORWARD) |
| Services | Parse `build.json` (name, category, host) | Same + add `auth` metadata to service records |

### gen-configs.ts changes

| Section | Before | After |
|---------|--------|-------|
| Caddy routes | Regex-parse Caddyfile (primary source) | Read from `build.json` auth blocks (primary) + Caddyfile parser (drift check) |
| Authelia ACL | Parse configuration.yml.tpl (primary) | Read from `build.json` auth blocks (primary) + Authelia parser (drift check) |
| Auth summary | Scattered across caddy/authelia sections | Unified per-service auth record from `build.json` |
| Drift report | Not implemented | **NEW** — compare declared (build.json) vs deployed (Caddyfile/Authelia) |
| ntfy, mailu, dns | Parse from service configs | **Keep unchanged** |

### Updated data flow (complete)

```
mesh-topology.nix ──nix eval──→ mesh-topology.json
        │                              │
        │                              ├──→ gen-topology.ts (VMs, WG mesh, firewall)
        │                              │
        ├──→ wireguard.nix             │
        ├──→ dnsmasq.nix              │
        ├──→ firewall.nix              │
        ├──→ Caddy flake (upstream IPs)│
        └──→ busybox httpd             │
                                       │
containerNetwork ──nix eval──→ container-network-{vm}.json
        │                              │
        ├──→ docker-network.nix        ├──→ gen-topology.ts (containers, IPs, ports, networks)
        ├──→ dnsmasq.nix              │
        ├──→ firewall.nix              │
        └──→ service flakes            │
                                       │
build.json auth ───────────────────────┤
        │                              ├──→ gen-configs.ts (auth routes, ACL, drift)
        ├──→ Caddy flake              │
        ├──→ Authelia flake            │
        └──→ OIDC audience            │
                                       │
Caddyfile (deployed) ──────────────────┤──→ gen-configs.ts (drift verification only)
Authelia config (deployed) ────────────┘
terraform main.tf ─────────────────────────→ gen-topology.ts (VM specs, unchanged)
DNS zone files ────────────────────────────→ gen-topology.ts + gen-configs.ts (unchanged)
ntfy/mailu configs ────────────────────────→ gen-configs.ts (unchanged)
```

---

## File Changes Summary

| File | Action | What |
|------|--------|------|
| **Home-Manager (b_infra/home-manager/)** | | |
| `_shared/mesh-topology.nix` | **NEW** | Shared WG mesh topology (peers, IPs, endpoints) |
| `_shared/modules/docker-network.nix` | **NEW** | Creates Docker networks with fixed subnets (parameterized) |
| `_shared/modules/dnsmasq.nix` | **NEW** | dnsmasq systemd service on host + config generation (parameterized) |
| `_shared/modules/web-server-busybox.nix` | **NEW** | busybox httpd serving ~/home on WG interface (parameterized) |
| `_shared/modules/firewall.nix` | **EDIT** | Add `containerNetwork` + `meshTopology` params, auto-generate DNAT + scoped WG FORWARD |
| `_shared/wireguard.nix` | **EDIT** | Read peers from `meshTopology` instead of hardcoded list |
| `_shared/modules/docker-service.nix` | **EDIT** | Keep `iptables: false` (confirmed correct) |
| `_shared/modules/shared-all.nix` | **NO CHANGE** | New modules are parameterized → imported explicitly per VM |
| `gcp-proxy/src/gcp-proxy.nix` | **EDIT** | Import `meshTopology`, add `containerNetwork` definition |
| `oci-apps/src/oci-apps.nix` | **EDIT** | Import `meshTopology`, add `containerNetwork` definition |
| `oci-mail/src/oci-mail.nix` | **EDIT** | Import `meshTopology`, add `containerNetwork` definition |
| `oci-analytics/src/oci-analytics.nix` | **EDIT** | Import `meshTopology`, add `containerNetwork` definition |
| `oci-apps-2/src/oci-apps-2.nix` | **EDIT** | Import `meshTopology`, add `containerNetwork` definition |
| `gcp-t4/src/gcp-t4.nix` | **EDIT** | Import `meshTopology`, add `containerNetwork` definition |
| **Services (a_solutions/)** | | |
| Every service `build.json` | **EDIT** | Add `auth` block (domain, policy, bearer, public paths) |
| `bb-sec_caddy/src/flake.nix` | **EDIT** | Auto-generate Caddyfile routes from `build.json` auth + `meshTopology` upstream IPs |
| `bb-sec_authelia/src/flake.nix` | **EDIT** | Auto-generate ACL + OIDC audience from `build.json` auth blocks |
| Every service `flake.nix` | **EDIT** | Replace `npm_default` → trust-zone network + `ipv4_address` + `dns: [gateway]` |
| **C3 Parsers (mcp-api-c3/src/engines/)** | | |
| `parsers/mesh-topology.ts` | **NEW** | Read `mesh-topology.json` (replaces ssh-config.ts + WG parts of wireguard.ts) |
| `parsers/container-network.ts` | **NEW** | Read `container-network-{vm}.json` (supplements compose.ts with declared IPs/ports) |
| `parsers/ssh-config.ts` | **DELETE** | Replaced by mesh-topology.ts |
| `parsers/wireguard.ts` | **EDIT** | Remove peer/firewall parsing, keep only as fallback or remove entirely |
| `parsers/build-json.ts` | **EDIT** | Extend to parse new `auth` field |
| `parsers/caddyfile.ts` | **REPURPOSE** | Keep parser, but use only for drift detection (compare declared vs deployed) |
| `parsers/authelia.ts` | **REPURPOSE** | Keep parser, but use only for drift detection (compare declared vs deployed) |
| `parsers/compose.ts` | **ADJUST** | Still parse for container names/images, supplement with containerNetwork for IPs/ports |
| `parsers/terraform.ts` | **KEEP** | No change — VM specs not in new data structures |
| `parsers/dns.ts` | **KEEP** | No change |
| `parsers/ntfy.ts` | **KEEP** | No change |
| `parsers/mailu.ts` | **KEEP** | No change |
| `engines/gen-topology.ts` | **EDIT** | Read from mesh-topology.json + container-network JSONs instead of regex parsing |
| `engines/gen-configs.ts` | **EDIT** | Read auth from build.json (primary), add drift detection vs deployed Caddy/Authelia |
| **Build Pipeline** | | |
| `build.sh` | **EDIT** | `cmd_config()`: add `nix eval` steps to export mesh-topology.json + container-network JSONs before running gen-topology/gen-configs |
| `.github/workflows/gen-configs.yml` | **EDIT** | Add trigger paths for `mesh-topology.nix`, VM `.nix` files |

---

## Execution Order

### Phase 1: Data layer (no deployment, no downtime)

1. **Create `mesh-topology.nix`** — extract peer data from current wireguard.nix
2. **Add `auth` blocks to all service `build.json` files** — formalize what's currently hardcoded in Caddy/Authelia
3. **Add `containerNetwork` to all VM `.nix` files** — define IPs, networks, ports per VM

### Phase 2: C3 parsers (read-only, no deployment impact)

4. **Create `mesh-topology.ts` parser** — reads mesh-topology.json
5. **Create `container-network.ts` parser** — reads container-network-{vm}.json
6. **Extend `build-json.ts`** — parse new `auth` field
7. **Update `gen-topology.ts`** — use new parsers instead of ssh-config/wireguard regex
8. **Update `gen-configs.ts`** — auth from build.json + drift detection via caddyfile.ts/authelia.ts
9. **Update `build.sh cmd_config()`** — add `nix eval` steps to export JSON before generators
10. **Verify**: run `build.sh config`, diff output against current topology/configs JSON. Must match.

### Phase 3: Home-manager modules (deploy to test VM first)

11. **Create modules** (docker-network.nix, dnsmasq.nix, web-server-busybox.nix)
12. **Update wireguard.nix** — read from `meshTopology` instead of hardcoded peers
13. **Update firewall.nix** — add `containerNetwork` + `meshTopology` params, auto-generate DNAT + scoped WG FORWARD
14. **Push home-manager for gcp-proxy only** → GHA deploys
15. **Verify gcp-proxy**: WG mesh still works, firewall rules correct, dnsmasq resolves

### Phase 4: Service flakes (one VM at a time)

16. **Update Caddy flake** — auto-generate Caddyfile from `build.json` auth + `meshTopology` upstream IPs
17. **Update Authelia flake** — auto-generate ACL + OIDC audience from `build.json` auth blocks
18. **Diff generated Caddy/Authelia configs against current** — must be equivalent before deploying
19. **Update gcp-proxy service flakes** (caddy, authelia, vaultwarden, ntfy, hickory-dns) — new networks + IPs
20. **Ship gcp-proxy services** (`build.sh ship` per service)
21. **Verify gcp-proxy**: containers resolve each other, ports forward, public access works, auth works (cookie + bearer)
22. **Repeat for each VM**: oci-apps, oci-mail, oci-analytics, oci-apps-2, gcp-t4

### Phase 5: Cleanup

23. **Delete `ssh-config.ts` parser** — fully replaced by mesh-topology.ts
24. **Remove WG/firewall regex parsing from `wireguard.ts`** — fully replaced
25. **Update GHA workflow** — add trigger paths for `mesh-topology.nix`, VM `.nix` files, `build.json` auth changes

**Rule: one VM at a time. Never push all VMs simultaneously.**
**Rule: Phase 2 (parsers) must produce identical output before Phase 3 starts.**

---

## Risk Notes

- **Migration**: Existing containers on `npm_default` need recreation on new networks — brief downtime per service
- **Mailu**: Keeps its own isolated network (172.22.0.32/28) — complex internal deps, mailu-front bridges to `apps` for Caddy access
- **dnsmasq binary**: Use nix `pkgs.dnsmasq` — guaranteed available on all VMs via home-manager, no Docker image needed
- **Port conflicts**: dnsmasq listens on Docker bridge gateways only (172.X.Y.1), NOT on 10.0.0.X or public IP — no conflict with Hickory DNS
- **busybox httpd**: Serving ~/home is a security consideration — WG-only binding mitigates this
- **Dual-network containers**: Services with `also = ["apps"]` get two veth pairs — negligible overhead, but verify DNS resolution uses the right gateway
- **Rollback**: If a VM breaks, revert its `.nix` config + re-ship services. Each VM is independent.
- **/28 limit**: 14 usable hosts per /28. Mailu has 8 containers — fits. If a service grows beyond 14, bump to /27.
- **wireguard.nix refactor**: Extracting peers to `mesh-topology.nix` is a refactor of a critical module — test on gcp-proxy first, verify all peers reconnect before touching other VMs.
- **Caddy/Authelia auto-generation**: First build with auto-generated configs — diff against current handwritten configs to verify no routes/ACL rules are missing before deploying.
- **build.json auth migration**: Adding `auth` to all `build.json` files is a one-time effort. Verify completeness by diffing generated Caddyfile against current one.
- **Parser migration**: Phase 2 (parsers) must produce identical JSON output to current parsers before any deployment. Run both old and new parsers, diff results. Any discrepancy means the new parser is missing data.
- **nix eval dependency**: `build.sh config` now needs `nix` available to export mesh-topology.json. On GHA this is already installed (cachix/install-nix-action). On VMs, nix is in home-manager PATH. On Termux, nix is available. No new dependency.
- **Drift detection false positives**: First run of drift detection will likely show differences (declared auth vs deployed configs may use different formatting). Normalize both sides before comparing.
