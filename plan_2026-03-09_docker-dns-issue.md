# Plan: Docker DNS + Fixed IPs + Declarative Networking

**Date**: 2026-03-09
**Root Cause**: Docker with `iptables: false` loses container DNS resolution and port forwarding. Docker engine restart/reboot wipes DNAT rules. Setting `iptables: true` conflicts with our declarative firewall.nix.

**Goal**: Full declarative control — we own DNS, IPs, firewall rules. Docker only runs containers.

---

## Current State

| Component | Current | Problem |
|-----------|---------|---------|
| Docker daemon | `iptables: false` in daemon.json | No auto DNAT/DNS for containers |
| Container DNS | Docker embedded DNS (broken with iptables:false) | Containers can't resolve each other by name |
| Container IPs | DHCP (random from 172.17.0.0/16) | IPs change on restart, can't write static firewall rules |
| Docker networks | `npm_default` (external, no subnet control) | No fixed IPs, no DNS |
| Hickory DNS | `.internal` zone on 10.0.0.1:53 (WG only) | Only VM-level resolution, not container-level |
| Firewall | firewall.nix owns INPUT/FORWARD/NAT | Works, but can't DNAT to random container IPs |
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
                                      (53/udp)    (53/udp)   (53/udp)
                                           │          │          │
                                      ┌────┘    ┌────┘    ┌────┘
                                      │         │         │
                                   containers  containers containers
                                   (fixed IP)  (fixed IP) (fixed IP)
                                   172.20.0.x  172.21.0.x 172.22.0.x
```

---

## Step 1: Define Docker Networks with Fixed Subnets

Each VM gets its own Docker bridge network with a dedicated subnet. All containers get fixed IPs.

### Subnet Allocation

| VM | Network Name | Subnet | Gateway |
|----|-------------|--------|---------|
| gcp-proxy | `infra` | 172.20.0.0/24 | 172.20.0.1 |
| oci-apps | `infra` | 172.21.0.0/24 | 172.21.0.1 |
| oci-mail | `infra` | 172.22.0.0/24 | 172.22.0.1 |
| oci-analytics | `infra` | 172.23.0.0/24 | 172.23.0.1 |
| oci-apps-2 | `infra` | 172.24.0.0/24 | 172.24.0.1 |
| gcp-t4 | `infra` | 172.25.0.0/24 | 172.25.0.1 |

### Fixed IP Assignments (per VM)

**gcp-proxy (172.20.0.0/24)**:

| Container | IP | Port |
|-----------|-----|------|
| dnsmasq | 172.20.0.2 | 53 |
| caddy | 172.20.0.10 | 80, 443 |
| authelia | 172.20.0.11 | 9091 |
| introspect-proxy | 172.20.0.12 | 4182 |
| vaultwarden | 172.20.0.13 | 80 |
| ntfy | 172.20.0.14 | 8090 |
| hickory-dns | 172.20.0.15 | 53 |
| redis | 172.20.0.16 | 6379 |

**oci-apps (172.21.0.0/24)**:

| Container | IP | Port |
|-----------|-----|------|
| dnsmasq | 172.21.0.2 | 53 |
| c3-api | 172.21.0.10 | 8081 |
| rig-agentic | 172.21.0.11 | 8090 |
| nocodb | 172.21.0.12 | 8085 |
| nocodb-db | 172.21.0.13 | — |
| mattermost | 172.21.0.14 | 8065 |
| mattermost-postgres | 172.21.0.15 | — |
| mattermost-bots | 172.21.0.16 | — |
| crawlee_redis | 172.21.0.20 | 6379 |
| crawlee_db | 172.21.0.21 | — |
| crawlee_minio | 172.21.0.22 | — |
| crawlee_scheduler | 172.21.0.23 | — |
| surrealdb | 172.21.0.30 | 8001 |
| lgtm_grafana | 172.21.0.40 | 3000 |
| lgtm_loki | 172.21.0.41 | 3100 |
| lgtm_mimir | 172.21.0.42 | — |
| lgtm_tempo | 172.21.0.43 | — |
| photoprism_app | 172.21.0.50 | 3013 |
| photoprism_mariadb | 172.21.0.51 | — |
| photoprism_rclone | 172.21.0.52 | — |
| gitea | 172.21.0.60 | 3000 |
| code-server | 172.21.0.61 | 8443 |
| cloud-spec | 172.21.0.62 | 3080 |
| orchestrator | 172.21.0.63 | — |
| hedgedoc_app | 172.21.0.70 | — |
| hedgedoc_postgres | 172.21.0.71 | — |
| grist_app | 172.21.0.72 | — |
| filebrowser_app | 172.21.0.73 | — |
| etherpad_app | 172.21.0.74 | — |
| etherpad_postgres | 172.21.0.75 | — |
| radicale | 172.21.0.76 | 5232 |
| revealmd_app | 172.21.0.77 | — |

**oci-mail (172.22.0.0/24)**:

| Container | IP | Port |
|-----------|-----|------|
| dnsmasq | 172.22.0.2 | 53 |
| mailu (front) | 172.22.0.10 | 25, 465, 993, 8444 |
| mailu (resolver) | 172.22.0.11 | 53 |
| syncthing | 172.22.0.20 | 8384 |
| radicale | 172.22.0.21 | 5232 |

**oci-analytics (172.23.0.0/24)**:

| Container | IP | Port |
|-----------|-----|------|
| dnsmasq | 172.23.0.2 | 53 |
| matomo | 172.23.0.10 | 8080 |
| windmill | 172.23.0.11 | — |

### Implementation

**New shared module**: `_shared/modules/docker-network.nix`

Creates the `infra` network on activation with the VM's subnet. Replaces `npm_default`.

```nix
# Pseudocode
{ vmSubnet }:
activation.script = ''
  docker network inspect infra >/dev/null 2>&1 || \
    docker network create infra --subnet ${vmSubnet} --gateway ${gateway}
'';
```

**Update each service flake.nix**: Replace `npm_default` external network with `infra` + fixed `ipv4_address` per container.

---

## Step 2: dnsmasq on Every VM

### New shared module: `_shared/modules/dnsmasq.nix`

dnsmasq runs as a **Docker container** on each VM with fixed IP `172.X.0.2`. All other containers use it as DNS.

**What dnsmasq resolves**:
- Container names → fixed IPs (local VM, from `/etc/dnsmasq.d/containers.conf`)
- Cross-VM service names → WireGuard IPs (from `/etc/dnsmasq.d/mesh.conf`)
- Everything else → upstream (Cloudflare 1.1.1.1 / Google 8.8.8.8)

**Generated config files** (by home-manager activation):

```
/etc/dnsmasq.d/
├── containers.conf    # host-record=caddy,172.20.0.10 (local containers)
├── mesh.conf          # host-record=oci-apps,10.0.0.6 (WG mesh peers)
└── upstream.conf      # server=1.1.1.1
```

**Docker Compose snippet** (injected into every service):
```yaml
services:
  dnsmasq:
    image: drewviles/dnsmasq:latest
    container_name: dnsmasq
    cap_add: [NET_ADMIN]
    restart: unless-stopped
    networks:
      infra:
        ipv4_address: 172.20.0.2
    volumes:
      - /etc/dnsmasq.d:/etc/dnsmasq.d:ro
    ports:
      - "127.0.0.1:53:53/udp"
      - "127.0.0.1:53:53/tcp"
```

**Every other container** gets:
```yaml
dns: ["172.X.0.2"]
```

This replaces Docker's built-in DNS (which breaks with `iptables: false`).

---

## Step 3: busybox httpd on Every VM (WG mesh only)

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

## Step 4: Declarative Firewall DNAT Rules

### Update `_shared/modules/firewall.nix`

With fixed container IPs, we can now write deterministic DNAT rules.

**New parameter**: `dnatRules` — list of port forwards from VM IP to container IP.

```nix
dnatRules = [
  # Public-facing (from any interface)
  { proto = "tcp"; dport = 80;  dest = "172.20.0.10:80"; }   # Caddy HTTP
  { proto = "tcp"; dport = 443; dest = "172.20.0.10:443"; }  # Caddy HTTPS

  # WireGuard-facing (from wg0 only)
  { proto = "tcp"; dport = 9091; dest = "172.20.0.11:9091"; iface = "wg0"; }  # Authelia
];
```

**Generated iptables**:
```bash
# NAT PREROUTING
iptables -t nat -A PREROUTING -p tcp --dport 80 -j DNAT --to-destination 172.20.0.10:80
iptables -t nat -A PREROUTING -p tcp --dport 443 -j DNAT --to-destination 172.20.0.10:443
iptables -t nat -A PREROUTING -i wg0 -p tcp --dport 9091 -j DNAT --to-destination 172.20.0.11:9091

# FORWARD (allow DNAT'd traffic)
iptables -A FORWARD -d 172.20.0.0/24 -j ACCEPT
```

This replaces Docker's auto-DNAT that we disabled with `iptables: false`.

---

## Step 5: Update Hickory DNS (optional enhancement)

Add container-level records to Hickory DNS for cross-VM container resolution:

```
; Container records (optional, dnsmasq handles local)
caddy.gcp-proxy.internal.    IN A 172.20.0.10
c3-api.oci-apps.internal.    IN A 172.21.0.10
```

**Lower priority** — dnsmasq handles local, and cross-VM access uses WG IPs + Caddy. But useful for direct container-to-container cross-VM communication.

---

## File Changes Summary

| File | Action | What |
|------|--------|------|
| `_shared/modules/docker-network.nix` | **NEW** | Creates `infra` Docker network with VM-specific subnet |
| `_shared/modules/dnsmasq.nix` | **NEW** | dnsmasq container + config generation |
| `_shared/modules/web-server-busybox.nix` | **NEW** | busybox httpd serving ~/home on WG interface |
| `_shared/modules/firewall.nix` | **EDIT** | Add `dnatRules` parameter for fixed DNAT |
| `_shared/modules/docker-service.nix` | **EDIT** | Keep `iptables: false` (confirmed correct) |
| `_shared/shared-all.nix` | **EDIT** | Import new modules |
| `gcp-proxy/src/gcp-proxy.nix` | **EDIT** | Add subnet, container IPs, DNAT rules |
| `oci-apps/src/oci-apps.nix` | **EDIT** | Add subnet, container IPs, DNAT rules |
| `oci-mail/src/oci-mail.nix` | **EDIT** | Add subnet, container IPs, DNAT rules |
| `oci-analytics/src/oci-analytics.nix` | **EDIT** | Add subnet, container IPs, DNAT rules |
| `oci-apps-2/src/oci-apps-2.nix` | **EDIT** | Add subnet, container IPs, DNAT rules |
| `gcp-t4/src/gcp-t4.nix` | **EDIT** | Add subnet, container IPs, DNAT rules |
| Every service `flake.nix` | **EDIT** | Replace `npm_default` → `infra` + `ipv4_address` + `dns: [172.X.0.2]` |

---

## Execution Order

1. **Create modules** (docker-network.nix, dnsmasq.nix, web-server-busybox.nix)
2. **Update firewall.nix** with dnatRules
3. **Update shared-all.nix** to import new modules
4. **Update VM configs** (subnet, IPs, DNAT rules per VM)
5. **Update service flakes** (one VM at a time, start with gcp-proxy as test)
6. **Push home-manager** → GHA deploys to all VMs
7. **Ship services** (`build.sh ship` per service with new docker-compose)
8. **Verify**: containers resolve each other, ports forward, WG mesh works, public access works

---

## Risk Notes

- **Migration**: Existing containers on `npm_default` need recreation on `infra` network — brief downtime per service
- **Mailu**: Already has its own subnet (192.168.203.0/24) — keep separate or migrate to `infra`?
- **dnsmasq image**: Verify aarch64 support for oci-apps/oci-apps-2 (ARM VMs)
- **Port conflicts**: dnsmasq on 53 may conflict with Hickory DNS on gcp-proxy — bind dnsmasq to 172.20.0.2:53 only (not 10.0.0.1:53)
- **busybox httpd**: Serving ~/home is a security consideration — WG-only binding mitigates this
