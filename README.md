# Cloud Infrastructure as Code

Self-hosted cloud across Oracle Cloud + Google Cloud free tiers. 5 VMs, 50+ containerized services, WireGuard mesh, fully declarative Nix flakes. Zero manual configuration — everything ships via `build.sh`.

---

## Table of Contents

### A) Documentation Overview
- [A.1 Architecture](#a1-architecture)
- [A.2 Virtual Machines](#a2-virtual-machines)
- [A.3 Active Services](#a3-active-services)
- [A.4 Cloud Providers](#a4-cloud-providers)
- [A.5 Quick Start](#a5-quick-start)
- [A.6 Authentication & Access](#a6-authentication--access)
- [A.7 Key Operations](#a7-key-operations)

### B) Architectural Design
- [B.1 Repository Structure](#b1-repository-structure)
- [B.2 Service Structure](#b2-service-structure)
- [B.3 build.json Schema](#b3-buildjson-schema)
- [B.4 Build Pipeline](#b4-build-pipeline)
- [B.5 Category Prefixes](#b5-category-prefixes)
- [B.6 Networking](#b6-networking)
- [B.7 CI/CD](#b7-cicd-github-actions)
- [B.8 Security Stack](#b8-security-stack)
- [B.9 Home Manager](#b9-home-manager)
- [B.10 Generated Data](#b10-generated-data-cloud-data)
- [B.11 MCP Servers](#b11-mcp-servers)
- [B.12 Matomo Hybrid Architecture](#b12-matomo-hybrid-architecture)

---

## A) Documentation Overview

### A.1 Architecture

```
Cloudflare (DNS + proxy + DDoS)
    → Caddy (gcp-proxy, TLS termination, Let's Encrypt)
        → Authelia (2FA: TOTP/WebAuthn, OIDC bearer tokens)
            → WireGuard mesh (10.0.0.0/24, hub-and-spoke)
                → Docker containers on target VM
```

### A.2 Virtual Machines

| VM | Alias | IP | WG IP | Arch | RAM | Availability |
|----|-------|----|-------|------|-----|-------------|
| gcp-E2-f_0 | gcp-proxy | 35.226.147.64 | 10.0.0.1 | x86_64 | 1 GB | 24/7 |
| oci-E2-f_0 | oci-mail | 130.110.251.193 | 10.0.0.3 | x86_64 | 1 GB | 24/7 |
| oci-E2-f_1 | oci-analytics | 129.151.228.66 | 10.0.0.4 | x86_64 | 1 GB | 24/7 |
| oci-A1-f_0 | oci-apps | 82.70.229.129 | 10.0.0.6 | aarch64 | 16 GB | 24/7 |
| gcp-T4-p_0 | gcp-t4 | — | 10.0.0.8 | x86_64 | 16 GB | on-demand |

SSH access: `ssh gcp-proxy`, `ssh oci-mail`, `ssh oci-analytics`, `ssh oci-apps`, `ssh gcp-t4`

### A.3 Active Services

| Service | Domain | VM | Port |
|---------|--------|----|------|
| Caddy Proxy | proxy.diegonmarcos.com | gcp-proxy | 80/443 |
| Authelia 2FA | auth.diegonmarcos.com | gcp-proxy | 9091 |
| Vaultwarden | vault.diegonmarcos.com | gcp-proxy | 80 |
| ntfy Push | rss.diegonmarcos.com | gcp-proxy | 8090 |
| Hickory DNS | dns.internal (WG only) | gcp-proxy | 53 |
| C3 Infra API | api.diegonmarcos.com/c3-api | oci-apps | 8081 |
| Crawlee Cloud | api.diegonmarcos.com/crawlee/ | oci-apps | 3000 |
| Mattermost | chat.diegonmarcos.com | oci-apps | 8065 |
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

### A.4 Cloud Providers

| Provider | Tier | Region | Purpose |
|----------|------|--------|---------|
| Oracle Cloud | Always Free (A1.Flex + E2.Micro) | eu-marseille-1 | 4 VMs |
| Google Cloud | Free Tier (e2-micro) + T4 GPU | us-central1 | 1-2 VMs |
| Cloudflare | Free | Global | DNS, proxy, DDoS |
| GitHub | Free | Global | CI/CD, Pages, Container Registry |

### A.5 Quick Start

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

### A.6 Authentication & Access

**Browser access**: Cloudflare → Caddy → Authelia forward-auth (cookie/session + 2FA via TOTP or WebAuthn).

**CLI/API access**: Bearer token via OIDC introspection.

```bash
# Get token (interactive, opens browser for 2FA)
python ~/git/vault/A0_keys/providers/authelia/oauth/get_token.py

# Use token
TOKEN=$(jq -r .access_token ~/git/vault/A0_keys/providers/authelia/oauth/authelia_tokens.json)
curl -H "Authorization: Bearer $TOKEN" https://photos.diegonmarcos.com/api/v1/status
```

### A.7 Key Operations

```bash
# Deploy any service
a_solutions/<service>/build.sh ship

# Matomo hybrid toggle (1GB VM constraint)
a_solutions/bc-obs_matomo/build.sh wake    # stops windmill, wakes matomo
a_solutions/bc-obs_matomo/build.sh sleep   # sleeps matomo, starts windmill

# Cloudflare DNS (Terraform)
a_solutions/ba-clo_cloudflare/build.sh

# Home Manager deploy (all VMs via GHA, or manual)
b_infra/home-manager/deploy.sh oci-apps
```

---

## B) Architectural Design

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
│   ├── home-manager/             Nix Home Manager (deployed via GHA)
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
├── config.json                   Master config (symlink → cloud-topology.json)
├── git.yaml                      Pre-push hooks (engine auto-regeneration)
└── .github/workflows/            CI/CD (auto-deploy on push to main)
```

### B.2 Service Structure

Every service in `a_solutions/` follows this mandatory template:

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

#### B.6.1 WireGuard Mesh
Hub-and-spoke topology. gcp-proxy (`10.0.0.1`) is the hub. All inter-VM traffic goes through WireGuard.

#### B.6.2 Traffic Flow
`Cloudflare → Caddy (gcp-proxy:443) → WireGuard → target VM:port`

#### B.6.3 Authentication
- **Browser**: Authelia forward-auth (cookie + 2FA)
- **CLI/API**: Bearer token via introspect-proxy (OIDC introspection)
- **SSH**: Key-based, aliases configured in vault

#### B.6.4 Docker Networking
Containers on shared Docker networks. Docker 29+ nftables DNAT handles WireGuard traffic automatically. No extra iptables rules needed.

### B.7 CI/CD (GitHub Actions)

| Workflow | Trigger | Target |
|----------|---------|--------|
| `ship-gcp-proxy.yml` | `bb-sec_caddy/`, `bb-sec_authelia/`, etc. | gcp-proxy |
| `ship-oci-apps.yml` | `bc-obs_c3-infra-mcp-api/`, `ad-agi_rig-agentic/`, etc. | oci-apps |
| `ship-oci-mail.yml` | `aa-sui_tools-mailu/`, etc. | oci-mail |
| `ship-oci-analytics.yml` | `bc-obs_*` services | oci-analytics |
| `home-manager.yml` | `b_infra/home-manager/` | all VMs |

All workflows: `cachix/install-nix-action` + SSH key + SOPS age key → `build.sh ship`.
Services with Docker images use `REMOTE_BUILD=true` (builds on target VM, avoids cross-compilation).
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
| Secrets | sops + age encryption, per-service secrets.yaml |
| Credentials | Vaultwarden (passwords), Aegis (TOTP) |

### B.9 Home Manager

All VMs use Nix Home Manager for reproducible user environments.

- **Deployment**: GHA workflow — x86_64 builds on runner + `nix copy`, aarch64 builds on-machine
- **Shared modules**: WireGuard, SSH container keys, Docker service, shell config
- **Per-VM overrides**: `b_infra/home-manager/hosts/`
- **6 VMs deployed**: gcp-proxy, gcp-t4, oci-mail, oci-analytics (x86_64), oci-apps (aarch64)

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
| `cloud-services` | HTTP (remote) | 20+ | Service API proxy (Matomo, Syncthing, Radicale, etc.) |
| `cloud-specs-docs` | stdio (local) | 16 | Knowledge retrieval (skills, specs, data, docs) |

### B.12 Matomo Hybrid Architecture

oci-analytics (1GB RAM) can't run Matomo + Windmill simultaneously. Matomo uses a hybrid container:

- **Awake**: MariaDB + Matomo PHP + Nginx (~160MB). Tracking goes direct to DB.
- **Sleeping**: Only receiver-nginx + receiver-php-fpm (~7MB). Tracking buffered to `/inbox/` JSON files.
- **Wake**: Imports buffered payloads, starts full Matomo, stops Windmill.

```bash
a_solutions/bc-obs_matomo/build.sh wake    # stops windmill, wakes matomo
a_solutions/bc-obs_matomo/build.sh sleep   # sleeps matomo, starts windmill
```

---

**Last Updated**: 2026-03-18
