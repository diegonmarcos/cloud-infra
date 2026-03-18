# Cloud Infrastructure Roadmap

> **Updated**: 2026-03-18
> **Owner**: Diego Nepomuceno Marcos

This is the master sequencing document. Each task has its own detailed TASK-*.md file. This document defines **order, dependencies, and rationale**.

---

## Dependency Graph

```
TASK-06 Engine v2
    └── TASK-05 GHCR Registry        (engine must work before new build strategy)

TASK-04 Declarative Networking
    └── TASK-08 Firewall Lockdown    (networking foundation before hardening)

TASK-07 Vault Secrets               (independent — security, any time)
TASK-01 Mail Direct SMTP            (blocked on OCI console, independent)
TASK-02 MCP API Coverage            (product work, independent)
TASK-00 Database Backup             (ops work, last)
```

---

## Execution Phases

### ▶ PHASE 1 — Engine Foundation
> Fix the build pipeline first. Everything else is deployed through `_engine.sh` — a broken engine means all subsequent changes deploy incorrectly.

---

#### TASK-06: `_engine.sh` v2 — Universal Build Pipeline
**File**: `TASK-20260313-06_Plan-engine-v2.md`
**Status**: Draft
**Why first**: Every service deploy goes through `_engine.sh`. The current engine has broken patterns (`REMOTE_BUILD` env var hack, `step_docker_remote` bypasses `dist/`, no health check, no deploy report). Fix this before deploying any of the other tasks.

**Delivers**:
- `build.json` declarative: `docker.build: "local"|"remote"|"compose"`
- `build.source: true` pattern for owned-code services (c3-mcp-api, rig-agentic)
- `step_health` — verify containers + HTTP after every ship
- `step_report` — POST deploy record to C3 API
- New ship order: `build → docker_local → secrets → deploy → docker_remote → compose → health → report`

**Unblocks**: TASK-05 (GHCR), TASK-02 (MCP)

---

### ▶ PHASE 2 — Security Hardening
> Two parallel tracks: secrets ownership (vault) and network lockdown (firewall). Both are independent of each other and can be worked in parallel.

---

#### TASK-07: Vault as Single Owner of All SOPS Secrets
**File**: `TASK-20260318-07_Plan-vault-secrets-ownership.md`
**Status**: Draft
**Why now**: Public repos (cloud, unix, front) currently contain sops ciphertext, age recipients, and key names. Vault is private — it should own all encrypted secrets. This is a pure security improvement with no service disruption.

**Delivers**:
- `vault/E0_secrets/` mirrors all secrets from cloud/unix/front
- `cloud/a_solutions/*/src/secrets.yaml` → symlinks to vault
- `cloud/.sops.yaml` moved to vault
- GHA clones vault via deploy key to resolve symlinks during CI
- Engine pipeline: `secrets` step runs before `build` (universal local+remote)

**Parallel with**: TASK-08

---

#### TASK-04: Declarative Networking — Docker DNS + Fixed IPs + Mesh
**File**: `TASK-20260309-04_Plan-declarative-networking.md`
**Status**: Planning complete, implementation pending
**Why before TASK-08**: TASK-08 (firewall lockdown) requires `iptables: false` in Docker. But Docker with `iptables: false` breaks container DNS and port forwarding unless we own DNS and routing ourselves. TASK-04 builds that ownership first.

**Delivers**:
- `mesh-topology.nix` — WG peer data as nix source of truth
- `docker-network.nix` — fixed container IPs per VM, declarative Docker networks
- `dnsmasq.nix` — internal DNS for `service.internal` names
- Caddy L4 plugin — SSH multiplexing over port 443
- wstunnel — WireGuard fallback over WebSocket (firewall bypass for WG)
- All service `build.json` files get `auth` block
- WG + firewall config auto-generated from `mesh-topology.nix`

**Unblocks**: TASK-08

---

#### TASK-08: Firewall Sovereign Lockdown
**File**: `TASK-20260318-08_Plan-firewall-sovereign-lockdown.md`
**Status**: Draft
**Depends on**: TASK-04 (networking must own DNS + routing before Docker iptables is disabled)

**Delivers**:
- `nftables-firewall.nix` module — pure nftables, loads via systemd `Before=docker.service`
- `networking.firewall.enable = false` — iptables-based firewall gone
- `"iptables": false` in Docker daemon — Docker cannot write any routing rules
- Per-VM explicit allowlists (only 7 public ports across all VMs)
- All services bind to WG IP (`10.0.0.X:PORT:PORT`) not `0.0.0.0`
- rpcbind disabled on all VMs
- SSH → WG-only after console access confirmed
- PostgreSQL 5432 removed from public internet

**Public ports after completion**:
| VM | Public ports |
|----|-------------|
| gcp-proxy | 80, 443, 443/udp, 51820/udp |
| oci-mail | 25, 465, 587, 993, 22000, 21027/udp, 51820/udp |
| oci-analytics | 51820/udp |
| oci-apps | 51820/udp |

---

### ▶ PHASE 3 — Build Modernization
> After engine v2 and security hardening are stable, modernize the container delivery strategy.

---

#### TASK-05: GHCR Container Registry
**File**: `TASK-20260313-05_Plan-ghcr-container-registry.md`
**Status**: TODO
**Depends on**: TASK-06 (engine v2 must support `docker.build: "local"` cleanly)

**Delivers**:
- GHA builds Docker images → pushes to `ghcr.io/diegonmarcos/<service>`
- VMs only do `docker compose pull` — no build tools needed on VM
- Eliminates `REMOTE_BUILD` (cross-arch ARM builds happen in GHA via QEMU)
- Multi-arch manifests: `linux/amd64` + `linux/arm64` in one image tag
- Targets: `c3-mcp-api`, `rust-api`, `rig-agentic` (currently the 3 REMOTE_BUILD services)

---

### ▶ PHASE 4 — Operational Completeness
> Service improvements and product features. No infrastructure risk.

---

#### TASK-01: Mailu Direct SMTP Delivery with OCI Relay Fallback
**File**: `TASK-20260306-01_Plan-mail-direct-smtp.md`
**Status**: Blocked on OCI console requests
**Depends on**: OCI unblocking port 25 outbound (support ticket)

**Delivers**:
- Mailu sends mail directly (port 25) without relay
- OCI relay as fallback if direct delivery is rejected
- Proper PTR/SPF/DKIM/DMARC for diegonmarcos.com

---

#### TASK-02: Service APIs — MCP Coverage
**File**: `TASK-20260306-02_Plan-mcp-api-coverage.md`
**Status**: Audit complete, implementation pending

**Delivers**:
- MCP tools for: ntfy, Matomo, Gitea, Ollama, Windmill, Authelia, Syncthing
- C3 as unified API gateway for all services
- C3 wrapper APIs for services with no REST (dozzle, redis, caddy, hickory-dns)

---

#### TASK-00: Database Backup
**File**: `TASK-20260207-00_Plan-database-backup.md`
**Status**: Partial — some backups exist, most VMs unprotected
**Why last**: No value in backing up data to a destination that may change during infra overhaul. Do this after networking + firewall are stable.

**Delivers**:
- Vaultwarden SQLite backup (systemd timer, gcp-proxy)
- PhotoPrism MariaDB backup (bup)
- Etherpad + HedgeDoc PostgreSQL backups (bup)
- Matomo MariaDB cron (oci-analytics)
- Windmill PostgreSQL backup (oci-analytics)
- All backup jobs declared in home-manager/service flakes

---

## Full Sequence Summary

```
NOW
 │
 ├─ PHASE 1 ──────────────────────────────────────────────────────
 │   TASK-06: Engine v2                    [~1 week]
 │
 ├─ PHASE 2 ──────────────────────────────────────────────────────
 │   TASK-07: Vault secrets     ──┐         [~2 days, parallel]
 │   TASK-04: Declarative net   ──┤         [~1 week]
 │   TASK-08: Firewall lockdown ──┘ (after 04)  [~3 days]
 │
 ├─ PHASE 3 ──────────────────────────────────────────────────────
 │   TASK-05: GHCR registry                [~2 days]
 │
 └─ PHASE 4 ──────────────────────────────────────────────────────
     TASK-01: Mail SMTP          (when OCI unblocks)
     TASK-02: MCP coverage       [~1 week]
     TASK-00: DB backup          [~3 days]
```

---

## State After All Phases Complete

```
Security
  ✓ All SOPS secrets in private vault repo only
  ✓ Public repos have symlinks, zero ciphertext
  ✓ nftables sovereign — Docker cannot bypass firewall
  ✓ 7 public ports total across all VMs (down from ~40)
  ✓ SSH accessible via WireGuard only
  ✓ All services bind to WG IP, not 0.0.0.0
  ✓ rpcbind disabled everywhere
  ✓ PostgreSQL not internet-routable

Networking
  ✓ Declarative mesh — WG peers, IPs, DNS all from nix source
  ✓ dnsmasq for internal *.internal DNS
  ✓ Fixed container IPs — no more dynamic Docker networking
  ✓ Caddy L4: SSH + HTTPS multiplexed on port 443
  ✓ WireGuard fallback: wstunnel over WSS port 443

Build Pipeline
  ✓ engine v2: declarative docker.build in build.json
  ✓ step_health + step_report on every deploy
  ✓ GHCR: images built in GHA, VMs only pull
  ✓ No more REMOTE_BUILD env var hacks

Operations
  ✓ All databases backed up with retention policy
  ✓ Mailu sends direct (no relay dependency)
  ✓ Full MCP tool coverage for all services
```
