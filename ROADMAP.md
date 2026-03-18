# Cloud Infrastructure Roadmap

> **Updated**: 2026-03-18
> **Owner**: Diego Nepomuceno Marcos

Master sequencing document. Each task has its own TASK-sec-*.md file. This defines **order, dependencies, and rationale**.

---

## Task Index

| ID | Name | File | Status |
|----|------|------|--------|
| sec-01 | Engine v2 + Pipeline | `TASK-sec-20260318-01_engine-v2-pipeline.md` | Draft |
| sec-02 | Vault Secrets Ownership | `TASK-sec-20260318-02_vault-secrets-ownership.md` | Draft |
| sec-03 | Declarative Networking + Firewall | `TASK-sec-20260318-03_declarative-networking-firewall.md` | Draft |
| sec-04 | GHCR Registry | `TASK-sec-20260318-04_ghcr-registry.md` | TODO |
| sec-05 | Database Backup | `TASK-sec-20260318-05_database-backup.md` | Partial |
| — | Mail Direct SMTP | `TASK-20260306-01_Plan-mail-direct-smtp.md` | Blocked (OCI) |
| — | MCP API Coverage | `TASK-20260306-02_Plan-mcp-api-coverage.md` | Pending |

### Merges Applied

| Old | Merged into | Reason |
|-----|------------|--------|
| TASK-06 (engine v2) | **sec-01** | + TASK-07 Phase 4 engine changes (secrets-first pipeline, symlink check) |
| TASK-07 (vault secrets) | **sec-02** | Minus Phase 4 (engine changes moved to sec-01) |
| TASK-04 (networking) + TASK-08 (firewall) | **sec-03** | Same scope: Docker iptables disabled, firewall ownership, service binds. Standardized on **nftables** |
| TASK-05 (GHCR) | **sec-04** | Updated dependencies |
| TASK-00 (backup) | **sec-05** | Updated VM names + dependency on sec-03 |

### Corrections Applied

1. **Pipeline conflict resolved**: sec-01 uses `secrets -> build` order (not `build -> secrets` from old TASK-06)
2. **Firewall standardized on nftables**: old TASK-04 used iptables, old TASK-08 used nftables — now unified as nftables throughout sec-03
3. **Engine changes centralized**: sec-02 (vault) has zero _engine.sh changes — all pipeline work in sec-01
4. **Two-layer bind model clarified**: Docker fixed IPs (172.x from containerNetwork) + WG-IP host bind (10.0.0.x) + nftables DNAT

---

## Dependency Graph

```
sec-01 Engine v2 + Pipeline
    |
    +-- sec-04 GHCR Registry (engine must work before new build strategy)
    |
sec-02 Vault Secrets (independent, parallel with sec-03)
    |
sec-03 Networking + Firewall (biggest task, networking + firewall unified)
    |
    +-- sec-05 Database Backup (stable infra before backup jobs)

Independent:
    TASK-01 Mail SMTP (blocked on OCI)
    TASK-02 MCP Coverage (product work)
```

---

## Execution Phases

### PHASE 1 — Engine Foundation

#### sec-01: Engine v2 + Secrets-First Pipeline
**Why first**: Every service deploy goes through `_engine.sh`. Fix the pipeline before deploying anything else.

**Delivers**:
- `build.json` declarative: `docker.build`, `build.source`, `build.pre_build`
- Secrets-first pipeline: `secrets -> build -> docker -> deploy -> compose -> health -> report`
- Symlink check in `step_secrets` (for vault symlinks from sec-02)
- Secrets preservation across `rm -rf dist/` in `step_build`
- `step_health` + `step_report` (POST to C3 API)

---

### PHASE 2 — Security Hardening (parallel tracks)

#### sec-02: Vault Secrets Ownership
**Parallel with sec-03** — no shared dependencies.

**Delivers**:
- `vault/E0_secrets/` owns all sops-encrypted secrets
- Public repos have symlinks only (zero ciphertext)
- GHA clones vault via deploy key
- `.sops.yaml` moved from cloud root to vault

#### sec-03: Declarative Networking + Firewall Lockdown
**Biggest task** — unified networking + security overhaul.

**Delivers**:
- `mesh-topology.nix` — WG peer data as nix source of truth
- `containerNetwork` per VM — fixed Docker IPs, trust-boundary networks
- `dnsmasq.nix` — host-level container DNS
- `nftables-firewall.nix` — sole firewall, loaded Before=docker.service
- Docker `iptables: false` — Docker cannot write any network rules
- All services bind to WG IP (not 0.0.0.0)
- Caddy L4 + wstunnel for port 443 fallback
- Auth auto-generation from `build.json` (Caddy routes + Authelia ACL)
- rpcbind disabled, PostgreSQL off public internet, SSH WG-only

**Public ports after completion** (7 total, down from ~40):

| VM | Public |
|----|--------|
| gcp-proxy | 80, 443, 443/udp |
| oci-mail | 25, 465, 587, 993, 22000, 21027/udp |
| oci-analytics | (none) |
| oci-apps | (none) |
| All VMs | 51820/udp (WireGuard) |

---

### PHASE 3 — Build Modernization

#### sec-04: GHCR Container Registry
**Depends on**: sec-01 (engine `docker.build: "local"`)

**Delivers**:
- GHA builds multi-arch images -> pushes to `ghcr.io/diegonmarcos/<service>`
- VMs only `docker compose pull` — no build tools needed
- Eliminates `REMOTE_BUILD` hack
- Targets: c3-mcp-api, rust-api, rig-agentic

---

### PHASE 4 — Operational Completeness

#### sec-05: Database Backup
**Depends on**: sec-03 (stable infra before backup jobs)

**Delivers**:
- Vaultwarden SQLite backup (systemd timer)
- PhotoPrism, Etherpad, HedgeDoc, Mattermost backups
- Matomo + Windmill backups
- All declared in home-manager/service flakes (never imperative)

#### TASK-01: Mail Direct SMTP
**Status**: Blocked on OCI port 25 outbound

#### TASK-02: MCP API Coverage
**Status**: Pending — ntfy, Matomo, Gitea, Ollama, Windmill, Authelia, Syncthing

---

## Full Sequence

```
NOW
 |
 +- PHASE 1 -------------------------------------------------------
 |   sec-01: Engine v2 + Pipeline
 |
 +- PHASE 2 -------------------------------------------------------
 |   sec-02: Vault secrets          (parallel)
 |   sec-03: Networking + Firewall  (parallel, biggest task)
 |
 +- PHASE 3 -------------------------------------------------------
 |   sec-04: GHCR registry
 |
 +- PHASE 4 -------------------------------------------------------
     sec-05: DB backup
     TASK-01: Mail SMTP           (when OCI unblocks)
     TASK-02: MCP coverage
```

---

## State After All Phases

```
Security
  + All SOPS secrets in private vault repo only
  + nftables sovereign — Docker cannot bypass firewall
  + 7 public ports total (down from ~40)
  + SSH via WireGuard only
  + All services bind to WG IP, not 0.0.0.0
  + PostgreSQL not internet-routable

Networking
  + Declarative mesh — WG peers, IPs, DNS from nix
  + dnsmasq for container DNS, Hickory for *.internal
  + Fixed container IPs, trust-boundary isolation
  + Caddy L4: SSH + HTTPS on port 443
  + WireGuard fallback: wstunnel over WSS

Build Pipeline
  + Secrets-first: secrets -> build -> docker -> deploy -> compose -> health -> report
  + Declarative docker.build in build.json
  + GHCR: images built in GHA, VMs only pull
  + step_health + step_report on every deploy

Operations
  + All databases backed up with retention
  + Full MCP tool coverage
```
