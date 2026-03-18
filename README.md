# Cloud Infrastructure as Code

Self-hosted cloud across Oracle Cloud + Google Cloud free tiers. 5 VMs, 50+ containerized services, WireGuard mesh, fully declarative Nix flakes. Zero manual configuration — everything ships via `build.sh`.

---

## A) Overview

### Architecture

```
Cloudflare (DNS + proxy)
    → Caddy (gcp-proxy, TLS termination)
        → Authelia (2FA: TOTP/WebAuthn, OIDC bearer tokens)
            → WireGuard mesh (10.0.0.0/24)
                → Docker containers on target VM
```

### Virtual Machines

| VM | Alias | IP | WG IP | Arch | RAM | Availability |
|----|-------|----|-------|------|-----|-------------|
| gcp-E2-f_0 | gcp-proxy | 35.226.147.64 | 10.0.0.1 | x86_64 | 1 GB | 24/7 |
| oci-E2-f_0 | oci-mail | 130.110.251.193 | 10.0.0.3 | x86_64 | 1 GB | 24/7 |
| oci-E2-f_1 | oci-analytics | 129.151.228.66 | 10.0.0.4 | x86_64 | 1 GB | 24/7 |
| oci-A1-f_0 | oci-apps | 82.70.229.129 | 10.0.0.6 | aarch64 | 16 GB | 24/7 |
| gcp-T4-p_0 | gcp-t4 | — | 10.0.0.8 | x86_64 | 16 GB | on-demand |

### Services

| Service | Domain | VM | Port |
|---------|--------|----|------|
| Caddy Proxy | proxy.diegonmarcos.com | gcp-proxy | 80/443 |
| Authelia 2FA | auth.diegonmarcos.com | gcp-proxy | 9091 |
| Vaultwarden | vault.diegonmarcos.com | gcp-proxy | 80 |
| ntfy Push | rss.diegonmarcos.com | gcp-proxy | 8090 |
| Hickory DNS | dns.internal (WG) | gcp-proxy | 53 |
| C3 API | api.diegonmarcos.com/c3-api | oci-apps | 8081 |
| Crawlee Cloud | api.diegonmarcos.com/crawlee/ | oci-apps | 3000 |
| Mailu Mail | mail.diegonmarcos.com | oci-mail | 8444 |
| Syncthing | sync.diegonmarcos.com | oci-mail | 8384 |
| Radicale | cal.diegonmarcos.com | oci-mail | 5232 |
| Matomo | analytics.diegonmarcos.com | oci-analytics | 8080 |
| Windmill | — | oci-analytics | — |
| PhotoPrism | photos.diegonmarcos.com | oci-apps | 3013 |
| NocoDB | db.diegonmarcos.com | oci-apps | 8085 |
| Code Server | ide.diegonmarcos.com | oci-apps | 8443 |
| AFFiNE | drive-notes-affine.diegonmarcos.com | oci-apps | 3010 |
| Ollama | — | gcp-t4 | 11434 |

### Quick Start

```bash
# Deploy a service (full pipeline: build → secrets → deploy → compose)
cd a_solutions/bb-sec_caddy && bash build.sh ship

# Build without deploying
bash build.sh build

# View secrets status
bash build.sh secrets

# SSH into a VM
ssh oci-apps
```

### Cloud Providers

| Provider | Tier | Region | Purpose |
|----------|------|--------|---------|
| Oracle Cloud | Always Free (A1.Flex + E2.Micro) | eu-marseille-1 | 4 VMs |
| Google Cloud | Free Tier (e2-micro) + T4 GPU | us-central1 | 1-2 VMs |
| Cloudflare | Free | Global | DNS, proxy, DDoS |
| GitHub | Free | Global | CI/CD, Pages, Container Registry |

---

## B) Engineering Specification

### B.1 Repository Structure

```
cloud/
├── a_solutions/                  50+ containerized services (Nix flakes)
│   ├── aa-sui_*                  Applications (AFFiNE, Code Server, Mailu, PhotoPrism...)
│   ├── ab-mic_*                  Microservices (Syncthing, Vaultwarden)
│   ├── ac-fin_*                  Financial (Crawlee Cloud, Quant Lab)
│   ├── ad-agi_*                  AI/AGI (Ollama, Rig Agentic)
│   ├── ba-clo_*                  Cloud providers (Cloudflare, gcloud, Hickory DNS)
│   ├── bb-sec_*                  Security (Authelia, Caddy, Orchestrator)
│   ├── bc-obs_*                  Observability (C3 API, Matomo, NocoDB, Windmill, LGTM)
│   ├── ca-dat_*                  Data (Gitea, KG Graph, Redis, Backups)
│   ├── _engine.sh                Shared build engine
│   └── z_archive/                Archived services
│
├── b_infra/                      VM infrastructure
│   ├── home-manager/             Nix Home Manager (deployed to all VMs via GHA)
│   │   ├── _shared/              Shared modules (WireGuard, SSH keys, Docker)
│   │   └── hosts/                Per-VM overrides
│   ├── vm_*/                     VM provisioning configs
│   └── vps_*/                    Cloud provider CLI configs
│
├── cloud-data/                   Generated data (auto-regenerated on push)
│   ├── cloud-topology.json       VMs, services, networking, DNS
│   ├── cloud-topology.md         Human-readable topology
│   ├── cloud-configs.json        Caddy routes, Authelia clients, DNS zones
│   ├── cloud-configs.md          Human-readable configs
│   └── cloud-deps.json           npm dependencies per service
│
├── config.json                   Master config (symlink to cloud-topology.json)
├── git.yaml                      Pre-push hooks (engine auto-regeneration)
└── .github/workflows/            CI/CD (auto-deploy on push to main)
```

### B.2 Service Structure (Mandatory)

Every service in `a_solutions/` follows this exact structure:

```
<category-prefix>_<name>/
├── build.sh        → ../_engine.sh (symlink)
├── build.json      Service config (name, deploy target, docker)
└── src/
    ├── flake.nix   Nix flake → generates docker-compose.yml + configs
    ├── secrets.yaml Optional, sops-encrypted (age key)
    └── ...          Service-specific source files
```

### B.3 build.json Schema

```json
{
  "name": "service-name",
  "description": "What this service does",
  "category": "sec",
  "domain": "service.diegonmarcos.com",
  "docker": {
    "registry": "ghcr.io",
    "image": "diegonmarcos/service-name",
    "dockerfile": "Dockerfile"
  },
  "deploy": {
    "host": "oci-apps",
    "remote_path": "/opt/containers/service-name",
    "sequential_restart": "true"
  },
  "build": { "include_config_json": "true" },
  "secrets": { "escape_dollars": "true" }
}
```

### B.4 Build Pipeline

| Command | Action |
|---------|--------|
| `build` | `nix build` in `src/` → copy result to `dist/` |
| `secrets` | `sops -d src/secrets.yaml` → `dist/.secrets` (KEY=VALUE) |
| `deploy` | `rsync dist/` → VM via SSH |
| `compose` | `docker compose up -d` on VM |
| `ship` | `build + secrets + deploy + compose` (full pipeline) |
| `clean` | Remove `dist/` and `.result` |

### B.5 Category Prefixes

| Prefix | Category | Description |
|--------|----------|-------------|
| `aa-sui_` | app | User-facing applications |
| `ab-mic_` | mic | Shared microservices |
| `ac-fin_` | fin | Financial / data pipelines |
| `ad-agi_` | agi | AI / LLM inference |
| `ba-clo_` | cloud | Cloud provider configs |
| `bb-sec_` | sec | Security & infrastructure |
| `bc-obs_` | tools | Observability & tooling |
| `ca-dat_` | data | Databases & backups |

### B.6 Networking

**WireGuard mesh**: Hub-and-spoke topology, gcp-proxy as hub (`10.0.0.1`).

**Traffic flow**: `Cloudflare → Caddy (gcp-proxy:443) → WireGuard → target VM:port`

**Authentication**:
- Browser: Authelia forward-auth (cookie + 2FA)
- CLI/API: Bearer token via introspect-proxy (OIDC introspection)
- SSH: Key-based, aliases configured in vault

**Docker networking**: Containers on shared Docker networks. Docker 29+ nftables DNAT handles WireGuard traffic automatically.

### B.7 CI/CD (GitHub Actions)

| Workflow | Trigger | Target |
|----------|---------|--------|
| `ship-gcp-proxy.yml` | `bb-sec_caddy/`, `bb-sec_authelia/`, etc. | gcp-proxy |
| `ship-oci-apps.yml` | `bc-obs_c3-infra-mcp-api/`, `ad-agi_rig-agentic/`, etc. | oci-apps |
| `ship-oci-mail.yml` | `aa-sui_tools-mailu/`, etc. | oci-mail |
| `ship-oci-analytics.yml` | `bc-obs_*` services | oci-analytics |
| `home-manager.yml` | `b_infra/home-manager/` | all VMs |

All workflows: `cachix/install-nix-action` + SSH key + SOPS age key → `build.sh ship`.
Services with Docker images use `REMOTE_BUILD=true` (builds on target VM).
All support `workflow_dispatch` for manual triggering.

**Push to `main` with changes in `a_solutions/*/src/` triggers auto-deploy.**

### B.8 Security Stack

| Layer | Components |
|-------|------------|
| Network Edge | Cloudflare Proxy, Cloud Firewalls |
| Traffic | Caddy Reverse Proxy, Let's Encrypt TLS |
| Authentication | Authelia 2FA (TOTP/WebAuthn), OIDC bearer tokens |
| Token Validation | introspect-proxy (OIDC introspection sidecar) |
| Application | Docker Networks, WireGuard VPN, Container Isolation |
| Credentials | Vaultwarden (passwords), Aegis (TOTP), sops+age (secrets) |

### B.9 Home Manager

All VMs use Nix Home Manager for reproducible environments.

- **Deployment**: GHA workflow, x86_64 builds on runner + `nix copy`, aarch64 builds on-machine
- **Modules**: WireGuard, SSH container keys, Docker service, shell config
- **Config**: `b_infra/home-manager/_shared/` (shared) + `hosts/` (per-VM overrides)

### B.10 Generated Data (cloud-data/)

Auto-regenerated by the C3 engine on every push via `git.yaml` pre-push hook:

| File | Engine | Content |
|------|--------|---------|
| `cloud-topology.json` | `gen-topology.ts` | VMs, services, WG mesh, SSH config |
| `cloud-topology.md` | `gen-topology.ts` | Human-readable topology tables |
| `cloud-configs.json` | `gen-configs.ts` | Caddy routes, Authelia clients, DNS zones |
| `cloud-configs.md` | `gen-configs.ts` | Human-readable config overview |
| `cloud-deps.json` | `gen-deps.ts` | npm dependencies per service (merged + per-service) |

Engine source: `a_solutions/bc-obs_c3-infra-mcp-api/src/engines/`

### B.11 MCP Servers

| Server | Type | Tools | Purpose |
|--------|------|-------|---------|
| `cloud-infra` | HTTP (remote) | 115+ | Infrastructure management (SSH, Docker, health, build, deploy) |
| `cloud-services` | HTTP (remote) | 20+ | Service API proxy (Matomo, Syncthing, etc.) |
| `cloud-skills` | stdio (local) | 16 | Knowledge retrieval (skills, specs, data, docs) |

### B.12 Key Operations

```bash
# Deploy a service
a_solutions/<service>/build.sh ship

# Matomo hybrid toggle (1GB VM constraint)
a_solutions/bc-obs_matomo/build.sh wake    # stops windmill, wakes matomo
a_solutions/bc-obs_matomo/build.sh sleep   # sleeps matomo, starts windmill

# Cloudflare DNS (Terraform)
a_solutions/ba-clo_cloudflare/build.sh

# Bearer token for CLI access
python ~/git/vault/A0_keys/providers/authelia/oauth/get_token.py
```

---

**Last Updated**: 2026-03-18
