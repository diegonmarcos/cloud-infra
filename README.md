```
╔═══════════════════════════════════════════════════════════════╗
║   ██████╗██╗      ██████╗ ██╗   ██╗██████╗                   ║
║  ██╔════╝██║     ██╔═══██╗██║   ██║██╔══██╗                  ║
║  ██║     ██║     ██║   ██║██║   ██║██║  ██║                  ║
║  ██║     ██║     ██║   ██║██║   ██║██║  ██║                  ║
║  ╚██████╗███████╗╚██████╔╝╚██████╔╝██████╔╝                  ║
║   ╚═════╝╚══════╝ ╚═════╝  ╚═════╝ ╚═════╝                   ║
║                                                               ║
║  5 VMs · 59 Services · WireGuard Mesh · Nix Flakes · IaC     ║
╚═══════════════════════════════════════════════════════════════╝
```

# Cloud Infrastructure as Code

Self-hosted cloud across Oracle Cloud + Google Cloud free tiers. 5 VMs, 59 containerized services, WireGuard mesh, fully declarative Nix flakes. Zero manual configuration — everything ships via `build.sh`.

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
- [B.10 Generated Data](#b10-generated-data-i_cloud-data)
- [B.11 MCP Servers](#b11-mcp-servers)
- [B.12 DTK (DevOps Toolkit)](#b12-dtk-devops-toolkit)
- [B.13 Matomo Hybrid Architecture](#b13-matomo-hybrid-architecture)

---

## A) Documentation Overview

### A.1 Architecture

```
Cloudflare (DNS + proxy + DDoS + Email Worker)
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

SSH access: `ssh gcp-proxy`, `ssh oci-mail`, `ssh oci-analytics`, `ssh oci-apps`

### A.3 Active Services

#### gcp-proxy (Security Gateway)

| Service | Domain | Description |
|---------|--------|-------------|
| Caddy | proxy.diegonmarcos.com | Reverse proxy + TLS termination |
| Authelia | auth.diegonmarcos.com | SSO and 2FA authentication portal |
| Introspect Proxy | — | OIDC token introspection sidecar for Caddy Bearer auth |
| Hickory DNS | dns.internal (WG only) | Internal DNS server for WireGuard mesh |
| Redis | — | In-memory data store |

#### oci-apps (Main Application Server)

| Service | Domain | Description |
|---------|--------|-------------|
| C3 Infra API | api.diegonmarcos.com/c3-api | Cloud Control Center REST API |
| C3 Infra MCP | mcp.diegonmarcos.com/c3-infra-mcp | Cloud Control Center MCP transport |
| C3 Services API | api.diegonmarcos.com/services | Service API gateway REST |
| C3 Services MCP | — | Service API gateway MCP transport |
| Cloud CGC MCP | — | Code Graph Context: infra knowledge + semantic code search |
| Cloud Spec | — | Unified Cloud Documentation Portal |
| Crawlee Cloud | api.diegonmarcos.com/crawlee/ | Apify-compatible scraping platform |
| Mattermost | chat.diegonmarcos.com | Team chat with ntfy bridge and C3 command bot |
| Mattermost MCP | — | Mattermost MCP server |
| PhotoPrism | photos.diegonmarcos.com | AI-powered photo management |
| Photos Webhook | — | PhotoPrism Webhook + S3 Processor |
| Code Server | ide.diegonmarcos.com | VS Code IDE |
| Gitea | git.diegonmarcos.com | Self-hosted Git service |
| Backup Gitea | git.diegonmarcos.com | Git backups and mirroring |
| Grist | sheets.diegonmarcos.com | Spreadsheet/database |
| HedgeDoc | doc.diegonmarcos.com | Collaborative markdown editor |
| Etherpad | pad.diegonmarcos.com | Collaborative editor |
| FileBrowser | files.diegonmarcos.com | Web file manager |
| Radicale | cal.diegonmarcos.com | CalDAV/CardDAV server |
| Vaultwarden | vault.diegonmarcos.com | Bitwarden password manager |
| ntfy | rss.diegonmarcos.com | Push notification server |
| DBGate | db.diegonmarcos.com | Universal database manager |
| LGTM | grafana.diegonmarcos.com | Grafana + Loki + Tempo + Mimir observability |
| KG Graph | — | SurrealDB hybrid knowledge graph |
| Sauron Central | — | Central syslog collector + SIEM API |
| Google Workspace MCP | — | Gmail, Calendar, Drive, Docs, Sheets via MCP |
| Mail MCP | — | IMAP/SMTP/Admin via Stalwart REST API |
| Rig Agentic (HAI 1.5B) | — | Lightweight Qwen 1.5B Q4 agent |
| Rig Agentic (Heavy 14B) | — | DeepSeek R1 14B Q8 agent with C3 MCP |
| Ollama HAI | — | ARM Ollama for hai agent + octocode |
| Quant Lab Full | — | Jupyter + Analytics + ML + NautilusTrader |
| Quant Lab Light | — | Lightweight Jupyter + NautilusTrader |
| Backup Borg | — | Media backups SSH server (Borg dedup) |
| Backup Bup | — | Database backups SSH server (bup) |
| Reveal.md | — | Reveal.js markdown presentations |

#### oci-mail (Mail Server)

| Service | Domain | Description |
|---------|--------|-------------|
| Maddy | mail.diegonmarcos.com | Mail server |
| SMTP Proxy | smtp.diegonmarcos.com | HTTP-to-SMTP bridge for CF Email Routing |
| SnappyMail | webmail.diegonmarcos.com | Webmail client |
| Syslog Forwarder | — | Log forwarding to central sauron |

#### oci-analytics (Analytics & Workflows)

| Service | Domain | Description |
|---------|--------|-------------|
| Matomo | analytics.diegonmarcos.com | Hybrid analytics (awake/sleep modes) |
| Umami | analytics.diegonmarcos.com/umami | Lightweight privacy-focused analytics |
| Dagu | workflows.diegonmarcos.com | DAG-based workflow scheduler |
| Dozzle | logs.diegonmarcos.com | Real-time Docker log viewer |
| Fluent Bit | — | Log processor and forwarder |
| Sauron Forwarder | — | Alert forwarding to central sauron |

#### Multi-VM / Local

| Service | Target | Description |
|---------|--------|-------------|
| DB Agent | all VMs | Central DB backup agent |
| Sauron Lite | all VMs | File integrity scanner |
| Cloudflare Worker | Cloudflare | Email routing worker (me@diegonmarcos.com) |
| Caddy L4 Image | GHCR | Custom Caddy with L4/ratelimit/CF DNS plugins |
| gcloud | local | Google Cloud SDK and tools |
| C3 Diego Personal Data MCP | local | READ-ONLY personal data access MCP |

### A.4 Cloud Providers

| Provider | Tier | Region | Purpose |
|----------|------|--------|---------|
| Oracle Cloud | Always Free (A1.Flex + E2.Micro) | eu-marseille-1 | 4 VMs |
| Google Cloud | Free Tier (e2-micro) + T4 GPU | us-central1 | 1-2 VMs |
| Cloudflare | Free | Global | DNS, proxy, DDoS, Email Routing |
| GitHub | Free | Global | CI/CD, Pages, Container Registry (GHCR) |

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
python ~/git/cloud-vault/A0_keys/providers/authelia/oauth/get_token.py

# Use token
TOKEN=$(jq -r .access_token ~/git/cloud-vault/A0_keys/providers/authelia/oauth/authelia_tokens.json)
curl -H "Authorization: Bearer $TOKEN" https://photos.diegonmarcos.com/api/v1/status
```

### A.7 Key Operations

```bash
# Deploy any service
a_solutions/<service>/build.sh ship

# Cloudflare DNS (Terraform)
c_vps/ba-clo_cloudflare/build.sh

# Home Manager deploy (all VMs via GHA, or manual per-VM)
b_infra/nixhm-sudo-oci-apps/_engine.sh ship
```

---

## B) Architectural Design

### B.1 Repository Structure

```
cloud/
├── a_solutions/                  59 containerized services (Nix flakes)
│   ├── aa-sui_*                  Applications (Code Server, Mattermost, PhotoPrism, Grist...)
│   ├── ab-mic_*                  Microservices (Vaultwarden)
│   ├── ac-fin_*                  Financial (Crawlee Cloud, Quant Lab)
│   ├── ad-agi_*                  AI/AGI (Ollama, Rig Agentic)
│   ├── ba-clo_*                  Cloud providers (Cloudflare Worker, gcloud, Hickory DNS)
│   ├── bb-sec_*                  Security (Authelia, Caddy, Orchestrator, Sauron)
│   ├── bc-obs_*                  Observability (C3 API/MCP, Matomo, Dagu, LGTM)
│   ├── ca-dat_*                  Data (Gitea, KG Graph, Redis, Backups, DB Agent)
│   ├── _engine.sh                Shared build engine (all build.sh symlink here)
│   ├── _shared/                  Shared Nix libs (docker.nix, templates)
│   ├── build.schema.json         JSON Schema for build.json validation
│   └── z_archive/                Archived services
│
├── b_infra/                      VM infrastructure
│   ├── home-manager/             Nix Home Manager (deployed via GHA)
│   │   ├── _engine.sh            HM build engine
│   │   ├── _shared/              40+ shared modules (system protection, containers, security)
│   │   ├── nixhm-sudo-gcp-proxy/ Per-VM configs (build.json + src/)
│   │   ├── nixhm-sudo-oci-analytics/
│   │   ├── nixhm-sudo-oci-apps/
│   │   ├── nixhm-sudo-oci-mail/
│   │   └── vm-pilot/             Base VM image (GHCR)
│   └── encrypt.sh                Secrets encryption helper
│
├── c_vps/                        Cloud provider configs
│   ├── ba-clo_cloudflare/        Terraform DNS management
│   ├── vps_aws/                  AWS CLI config
│   ├── vps_gcloud/               Google Cloud CLI config
│   ├── vps_hetzner/              Hetzner CLI config
│   ├── vps_nvidia-llm-api/       NVIDIA LLM API config
│   ├── vps_oci/                  Oracle Cloud CLI config
│   ├── vps_resend/               Resend email API config
│   └── vps_vast-ai/              Vast.ai GPU rental config
│
├── d_myhardware/                 Local hardware configs
│   ├── local_SurfacePro8/        Surface Pro 8
│   └── local_s21/                Samsung S21
│
├── I_cloud-data/                 Generated data hub (26 JSON files, auto-regenerated)
│   ├── engines/                  TypeScript generators (derive + gen)
│   ├── cloud-data-topology.json  VMs, services, networking, DNS
│   ├── cloud-data-configs.json   Caddy routes, Authelia clients, DNS zones
│   ├── cloud-data-deps.json      npm dependencies per service
│   ├── build-caddy.json
│   ├── cloud-data-authelia-acl.json
│   ├── cloud-data-wireguard-peers.json
│   ├── cloud-data-firewall-rules.json
│   ├── cloud-data-containers-*.json  Per-VM container specs (5 files)
│   ├── cloud-data-home-manager.json
│   ├── cloud-data-gha-config.json
│   ├── cloud-data-backup-targets.json
│   ├── cloud-data-databases.json
│   ├── cloud-data-monitoring-targets.json
│   ├── cloud-data-dns-services.json
│   ├── cloud-data-cloudflare-dns.json
│   ├── cloud-data-matomo-sites.json
│   ├── cloud-data-ntfy-acl.json
│   ├── cloud-data-log-routing.json
│   ├── cloud-data-container-resources.json
│   ├── cloud-data-service-connections.json
│   ├── cloud-data-secrets-env-var-names.json
│   ├── _cloud-data-consolidated.json  All data merged
│   ├── manifest.json             Index of all generated files
│   ├── reports/                  Generated reports
│   ├── workflows/                Generated workflow configs
│   └── index.html + style.css    Cloud-data web portal
│
├── II_tools/                     DevOps Toolkit (DTK)
│   ├── dtk.sh                    Main DTK entry point
│   ├── deps.json                 Tool dependencies
│   ├── deps-apt.json             APT package dependencies
│   ├── 1-cmds-local/             Local machine commands
│   ├── 2-cmds-cloud/             Cloud/VM commands
│   ├── 3-dashboards/             Monitoring dashboards
│   ├── 4-setups/                 Setup scripts
│   ├── 5-infos/                  Info/diagnostic scripts
│   └── 6-unix-mcp-api/           MCP API tools
│
├── a0_docs/                       Architecture documentation
│   ├── Cloud-spec.md             Cloud specification
│   ├── cloud_architecture.json   Architecture data
│   └── cloud_control.json        Control plane data
│
├── 9_others/                    Repo configuration engine (dotfiles + CI/CD)
│   ├── build.sh                  Config + workflow builder
│   └── src/                      git-repo/ git-hooks/ gha/ app-claude/
│                                 app-vscode/ app-obsidian/ engines/ scripts/
│
├── .github/workflows/            GitHub Actions CI/CD
│   ├── ship.yml                  Unified ship workflow (auto-deploy on push)
│   ├── ship-gen-configs.yml      Regenerate cloud-data configs
│   ├── ship-home-manager.yml     Deploy home-manager to all VMs
│   ├── ship-terraform.yml        Apply Terraform changes
│   ├── health.yml                Health check workflow
│   └── sync-submodules.yml       Auto-sync submodules
│
├── config.json                   Master config (topology + service registry)
├── build.sh                      Repo-level build entry point
├── build_fallback.json           Fallback deployment profile
├── git.sh                        Git hooks helper
├── git.yaml                      Pre-push hooks (engine auto-regeneration)
└── cloud-*.md / cloud-*.json     Symlinks → I_cloud-data/ (convenience)
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

Validated against `a_solutions/build.schema.json`:

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

| Prefix | Category | Count | Description |
|--------|----------|-------|-------------|
| `aa-sui_` | app | 15 | User-facing applications |
| `ab-mic_` | mic | 1 | Shared microservices |
| `ac-fin_` | fin | 3 | Financial / data pipelines |
| `ad-agi_` | agi | 4 | AI / LLM inference |
| `ba-clo_` | cloud | 3 | Cloud provider configs |
| `bb-sec_` | sec | 6 | Security & infrastructure |
| `bc-obs_` | tools | 19 | Observability & tooling |
| `ca-dat_` | data | 8 | Databases & backups |

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

#### B.6.5 Email Routing
`Cloudflare Email Worker → SMTP Proxy (oci-mail) → Maddy`

### B.7 CI/CD (GitHub Actions)

Unified ship workflow (`ship.yml`) replaces per-VM workflows:

| Workflow | Trigger | Target |
|----------|---------|--------|
| `ship.yml` | `a_solutions/*/src/**` push to main | Auto-detects target VM from build.json |
| `ship-gen-configs.yml` | cloud-data regeneration | Commits updated JSONs |
| `ship-home-manager.yml` | `b_infra/` | all VMs |
| `ship-terraform.yml` | `c_vps/ba-clo_cloudflare/` | Cloudflare DNS |
| `health.yml` | scheduled / manual | Health checks |
| `sync-submodules.yml` | scheduled / manual | Submodule sync |

All workflows: `cachix/install-nix-action` + SSH key + SOPS age key → `build.sh ship`.
Services with Docker images use `REMOTE_BUILD=true` (builds on target VM, avoids cross-compilation).
All support `workflow_dispatch` for manual triggering with optional service/VM filter.

**Push to `main` with changes in `a_solutions/*/src/` triggers auto-deploy.**

### B.8 Security Stack

| Layer | Components |
|-------|------------|
| Network Edge | Cloudflare Proxy, Cloud Firewalls |
| Traffic | Caddy Reverse Proxy (L4 + L7), Let's Encrypt TLS |
| Authentication | Authelia 2FA (TOTP/WebAuthn), OIDC bearer tokens |
| Token Validation | introspect-proxy (OIDC introspection sidecar) |
| Application | Docker Networks, WireGuard VPN, Container Isolation |
| Monitoring | Sauron Central (SIEM), Sauron Lite (file integrity), Sauron Forwarder |
| Secrets | sops + age encryption, per-service secrets.yaml |
| Credentials | Vaultwarden (passwords), Aegis (TOTP) |
| System Protection | 3-tier cgroup slices, FIFO scheduler on critical services, watchdog |

### B.9 Home Manager

All VMs use Nix Home Manager for reproducible user environments. Deployed as Docker images via GHCR.

```
b_infra/
├── _engine.sh              HM build engine
├── _shared/                40+ shared modules
│   ├── modules/            System protection, containers, security, networking
│   ├── wireguard.nix       WireGuard mesh config
│   ├── httpd.nix           Web server config
│   └── secrets.yaml        Shared secrets (sops-encrypted)
├── nixhm-sudo-gcp-proxy/  Per-VM (x86_64)
├── nixhm-sudo-oci-analytics/ Per-VM (x86_64)
├── nixhm-sudo-oci-apps/   Per-VM (aarch64)
├── nixhm-sudo-oci-mail/   Per-VM (x86_64)
└── vm-pilot/               Base VM image (GHCR)
```

Key shared modules:
- **System protection**: 3-tier cgroup slices, FIFO/RR scheduling, watchdog, resource bouncer, OOM guards
- **Container control**: Docker lifecycle daemon, init, firewall, network, resources, security
- **Security**: SSH hardening, authorized keys, secrets substitution, serial console autologin
- **Networking**: WireGuard, Hickory DNS client, firewall rules
- **Packages**: Data-driven from `system-packages.json` and cloud-data JSONs

### B.10 Generated Data (I_cloud-data/)

Auto-regenerated by the C3 engine on every push via `git.yaml` pre-push hook. 26 JSON files covering every aspect of infrastructure:

| File | Content |
|------|---------|
| `cloud-data-topology.json` | VMs, services, WG mesh, SSH config |
| `cloud-data-configs.json` | Caddy routes, Authelia clients, DNS zones |
| `cloud-data-deps.json` | npm dependencies per service |
| `build-caddy.json` | Caddy reverse proxy route definitions |
| `cloud-data-authelia-acl.json` | Authelia access control policies |
| `cloud-data-wireguard-peers.json` | WireGuard peer configs per VM |
| `cloud-data-firewall-rules.json` | Per-VM firewall rules |
| `cloud-data-containers-{vm}.json` | Per-VM Docker container specs (5 files) |
| `cloud-data-home-manager.json` | HM module config per VM |
| `cloud-data-gha-config.json` | GitHub Actions workflow config |
| `cloud-data-backup-targets.json` | Backup strategy per service |
| `cloud-data-databases.json` | Database inventory |
| `cloud-data-monitoring-targets.json` | Monitoring endpoints |
| `cloud-data-dns-services.json` | DNS records per service |
| `cloud-data-cloudflare-dns.json` | Cloudflare DNS zone records |
| `cloud-data-matomo-sites.json` | Matomo tracked sites |
| `cloud-data-ntfy-acl.json` | ntfy topic ACLs |
| `cloud-data-log-routing.json` | Fluent Bit log routing |
| `cloud-data-container-resources.json` | Docker resource limits |
| `cloud-data-service-connections.json` | Service-to-service dependencies |
| `cloud-data-secrets-env-var-names.json` | Required secret env vars per service |
| `_cloud-data-consolidated.json` | All data merged into one file |

Engine source: `I_cloud-data/1_workflows/src/scripts/` (cloud-data-config.ts + parsers/ + templates/)

### B.11 MCP Servers

| Server | Type | Tools | Purpose |
|--------|------|-------|---------|
| `c3-infra-mcp` | HTTP (remote) | 70+ | Infrastructure management (SSH, Docker, health, build, deploy, cloud ops) |
| `c3-services-mcp` | HTTP (remote) | 20+ | Service API proxy (Matomo, Radicale, PhotoPrism, etc.) |
| `cloud-cgc-pub-mcp` | HTTP (remote) + stdio (local) | 50+ | Knowledge graph, specs, docs, skills, Octocode semantic search |
| `cloud-vault-mcp` | stdio (local) | 16 | READ-ONLY personal data access (vault, identity, comms, media) |
| `google-workspace-mcp` | HTTP (remote) | — | Gmail, Calendar, Drive, Docs, Sheets |
| `mattermost-mcp` | HTTP (remote) | — | Mattermost chat tools |
| `cloud-mail-mcp` | HTTP (remote) | — | IMAP/SMTP/Admin via Stalwart REST API |

### B.12 DTK (DevOps Toolkit)

`II_tools/` contains the DevOps Toolkit — a collection of shell scripts and MCP API tools organized by purpose:

| Directory | Purpose |
|-----------|---------|
| `1-cmds-local/` | Local machine commands |
| `2-cmds-cloud/` | Cloud/VM remote commands |
| `3-dashboards/` | Monitoring dashboards |
| `4-setups/` | Initial setup scripts |
| `5-infos/` | Diagnostic and info scripts |
| `6-unix-mcp-api/` | MCP API tooling |

Available as MCP tools via `dtk_*` commands (see DTK MCP server).

### B.13 Matomo Hybrid Architecture

oci-analytics (1GB RAM) uses a hybrid container for Matomo:

- **Awake**: MariaDB + Matomo PHP + Nginx (~160MB). Tracking goes direct to DB.
- **Sleeping**: Only receiver-nginx + receiver-php-fpm (~7MB). Tracking buffered to `/inbox/` JSON files.
- **Wake**: Imports buffered payloads, starts full Matomo.

```bash
a_solutions/bc-obs_matomo/build.sh wake    # wakes matomo
a_solutions/bc-obs_matomo/build.sh sleep   # sleeps matomo
```

---

**Last Updated**: 2026-04-15
