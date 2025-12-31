# Cloud Enterprise Platform - Project Handoff

> [!info] Document Info
> **Version:** 3.0 | **Updated:** 2025-12-26
> **Owner:** Diego Nepomuceno Marcos
> **Path:** `/home/diego/Documents/Git/back-System/cloud/0.spec/v3/`
> **UI Design:** [[Cloud_Portal_canvas.canvas|Cloud Portal Canvas]]

---

## Table of Contents

> [!abstract] Navigation
>
> **A.** [[#A. PRODUCT ARCHITECTURE]] - What & Why
>   - [[#A.0 Product Catalog & Vision]]
>   - [[#A.1 Security Architecture]]
>   - [[#A.2 Data Architecture]]
>   - [[#A.3 Cloud Control Center]]
>   - [[#A.4 Frontend Development]]
>
> **B.** [[#B. TECHNICAL DESIGN]] - How to build *(TBD)*
>
> **C.** [[#C. ROADMAP]] - When to deploy
>   - [[#C.0 Status Matrix]]
>
> **D.** [[#D. DEVOPS]] - How to operate
>   - [[#D.0 SSH Access]]
>   - [[#D.1 Docker Commands]]
>   - [[#D.2 Service Health Checks]]
>   - [[#D.3 Backup Commands]]
>   - [[#D.4 Wake-on-Demand (oci-p-flex_1)]]
>
> **X.** [[#X. APPENDIX]] - References & Practices
>   - [[#X.0 Technical Research]]
>   - [[#X.1 Code Repository Structure]]
>   - [[#X.2 Secrets & Access Management]]
>   - [[#X.3 Frontend Practices]]

---

> [!list] Full Table of Contents
>
> **[[#A. PRODUCT ARCHITECTURE]]** - What & Why
> - [[#A.0 Product Catalog & Vision]]
>   - [[#A.0.0 General Products & Tools]]
>   - [[#A.0.1 AI Products & Stack]]
>   - [[#A.0.2 User Apps]]
> - [[#A.1 Security Architecture]]
>   - [[#A.1.0 User Auth (Passwordless SSO/OAuth2/OIDC)]]
>   - [[#A.1.1 Defense Layers]]
>   - [[#A.1.2 Security Monitors]]
> - [[#A.2 Data Architecture]]
>   - [[#A.2.0 Databases]]
>   - [[#A.2.1 Central Backups]]
>   - [[#A.2.2 Central Logs]]
>   - [[#A.2.3 Cloud API & MCP Layer]]
> - [[#A.3 Cloud Control Center]]
>   - [[#A.3.0 C3 CLI]]
>   - [[#A.3.1 Cloud Monitor Engine]]
>   - [[#A.3.2 Cloud Debug Engine]]
>   - [[#A.3.3 Cloud Audit Sync Engine]]
>   - [[#A.3.4 VM Infrastructure Matrix]]
> - [[#A.4 Frontend Development]]
>   - [[#A.4.0 Cloud Portal]]
>   - [[#A.4.1 Build Stack]]
>   - [[#A.4.2 Folder Structure]]
>   - [[#A.4.3 Pages & Components]]
>
> **[[#B. TECHNICAL DESIGN]]** - How to build (TBD)
>
> **[[#C. ROADMAP]]** - When to deploy
> - [[#C.0 Status Matrix]]
>   - [[#Production Services (ON)]]
>   - [[#Wake-on-Demand Services (WAKE)]]
>   - [[#Under Development (DEV)]]
>   - [[#Roadmap Phases]]
>
> **[[#D. DEVOPS]]** - How to operate
> - [[#D.0 SSH Access]]
> - [[#D.1 Docker Commands]]
> - [[#D.2 Service Health Checks]]
> - [[#D.3 Backup Commands]]
> - [[#D.4 Wake-on-Demand (oci-p-flex_1)]]
>
> **[[#X. APPENDIX]]** - References & Practices
> - [[#X.0 Technical Research]]
> - [[#X.1 Code Repository Structure]]
> - [[#X.2 Secrets & Access Management]]
>   - [[#X.2.0 Architecture]]
>   - [[#X.2.1 Folder Structure]]
>   - [[#X.2.2 Data Inventory]]
>   - [[#X.2.3 Security Stack]]
>   - [[#X.2.4 VM SSH Quick Reference]]
>   - [[#X.2.5 Cloud Credentials]]
>   - [[#X.2.6 Backup Strategy]]
>   - [[#X.2.7 Export Commands]]
> - [[#X.3 Frontend Practices]]
>   - [[#X.3.0 CI/CD Pipeline]]
>   - [[#X.3.1 Build System & DevOps]]
>   - [[#X.3.2 Code Practices]]
>   - [[#X.3.3 Analytics (Matomo)]]

---

# A. PRODUCT ARCHITECTURE

> [!tip] Purpose
> Defines **what** we're building and **why**

## A.0 Product Catalog & Vision

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     CLOUD ENTERPRISE PLATFORM                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐              │
│  │   WEB PORTAL    │  │    CLI APPS     │  │  AI INTERFACES  │              │
│  │  (User Entry)   │  │  (Dev Entry)    │  │  (Agent Entry)  │              │
│  └────────┬────────┘  └────────┬────────┘  └────────┬────────┘              │
│           │                    │                    │                        │
│           ▼                    ▼                    ▼                        │
│  ┌─────────────────────────────────────────────────────────────────┐        │
│  │                      PRODUCT LAYER                               │        │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐            │        │
│  │  │ General  │ │    AI    │ │   User   │ │   Dev    │            │        │
│  │  │ Products │ │ Products │ │   Apps   │ │   Apps   │            │        │
│  │  └──────────┘ └──────────┘ └──────────┘ └──────────┘            │        │
│  └─────────────────────────────────────────────────────────────────┘        │
│           │                    │                    │                        │
│           ▼                    ▼                    ▼                        │
│  ┌─────────────────────────────────────────────────────────────────┐        │
│  │                    INFRASTRUCTURE LAYER                          │        │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐            │        │
│  │  │ Security │ │   Data   │ │  Cloud   │ │ Frontend │            │        │
│  │  │   A.1    │ │   A.2    │ │ Control  │ │   Dev    │            │        │
│  │  │          │ │          │ │   A.3    │ │   A.4    │            │        │
│  │  └──────────┘ └──────────┘ └──────────┘ └──────────┘            │        │
│  └─────────────────────────────────────────────────────────────────┘        │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### A.0.0 General Products & Tools

> [!note] Web Portal Products
> Self-hosted alternatives to commercial cloud services

| Category | Product | Domain | Status | Technology |
|----------|---------|--------|--------|------------|
| **Inbox** | Mail & Calendar | mail.diegonmarcos.com | ON | Mailu + Radicale |
| **Inbox** | Feed (RSS) | - | DEV | TBD |
| **Object Files** | Photos | photos.app.diegonmarcos.com | WAKE | Photoprism |
| **Object Files** | Drive & Suite | - | DEV | TBD |
| **Media** | Music | - | DEV | Navidrome |
| **Media** | Videos & Movies | - | DEV | Jellyfin |
| **Me** | Linktree | diegonmarcos.com | ON | GitHub Pages |
| **Me** | Maps | - | DEV | TBD |

---

### A.0.1 AI Products & Stack

> [!note] AI Infrastructure
> Self-hosted AI with MCP integration for Claude agents

#### AI Philosophy

1. **Self-Hosted First**: Own GPU infrastructure over API dependency
2. **Cost Optimization**: Spot instances, wake-on-demand, model quantization
3. **Privacy**: Local inference for sensitive data
4. **MCP Integration**: Claude agents access infrastructure via tools

#### AI Infrastructure (TensorDock)

| VM | Purpose | GPU | RAM | Storage | Cost |
|----|---------|-----|-----|---------|------|
| ai-vm-1 | Inference | RTX 3090 | 32 GB | 100 GB NVMe | ~$0.30/hr |
| ai-vm-2 | Training | RTX 4090 | 64 GB | 500 GB NVMe | ~$0.50/hr |

#### AI Products

| Product | Purpose | Stack | Status |
|---------|---------|-------|--------|
| Open WebUI | Chat interface | Open WebUI + Ollama | DEV |
| Prompt Library | Prompt management | PostgreSQL + API | DEV |
| MLflow | Model tracking | MLflow + MinIO | DEV |

#### MCP Tools (7 tools for Claude)

| Tool | Purpose | Endpoint |
|------|---------|----------|
| `cloud_status` | Get VM/service status | `/api/status` |
| `cloud_ssh` | Execute SSH commands | `/api/ssh` |
| `cloud_logs` | Fetch container logs | `/api/logs` |
| `cloud_metrics` | Get performance metrics | `/api/metrics` |
| `cloud_deploy` | Trigger deployments | `/api/deploy` |
| `cloud_backup` | Manage backups | `/api/backup` |
| `cloud_dns` | Manage Cloudflare DNS | `/api/dns` |

---

### A.0.2 User Apps

> [!note] Cloud Connect Super App
> Single entry point for all user cloud services

#### Cloud Connect Components

| Component | Purpose | Technology |
|-----------|---------|------------|
| **VPN** | Secure tunnel to cloud | WireGuard |
| **Vault** | Password/secret access | Bitwarden CLI |
| **Computer Configs** | Linux config sync | Syncthing + dotfiles |
| **Data Configs** | API/MCP URLs | JSON config files |
| **Mount** | Remote filesystem | rclone + FUSE |
| **SSH** | Terminal access | OpenSSH |

#### Connection Flow

```
User Device
    │
    ├── VPN Connect (WireGuard)
    │       │
    │       ▼
    ├── Vault Unlock (Bitwarden)
    │       │
    │       ▼
    ├── Mount Remote (rclone)
    │       │
    │       ▼
    └── Access Services (SSH/Web)
```

---

## A.1 Security Architecture

> [!warning] Security Philosophy
> Defense in depth with 4 layers: Edge → Network → Auth → Application

### A.1.0 User Auth (Passwordless SSO/OAuth2/OIDC)

#### Authentication Methods

| Method | Use Case | Provider |
|--------|----------|----------|
| **Authelia 2FA** | Web services (Photoprism, Matomo, NPM) | authelia/authelia |
| **OIDC** | OAuth2 flows | Authelia as IdP |
| **Passkeys** | Passwordless login | WebAuthn + YubiKey |
| **TOTP** | Backup 2FA | Aegis + Garmin |

#### Authelia Configuration

```yaml
# Protected domains
access_control:
  default_policy: deny
  rules:
    - domain: photos.app.diegonmarcos.com
      policy: two_factor
    - domain: analytics.diegonmarcos.com
      policy: two_factor
    - domain: proxy.diegonmarcos.com
      policy: two_factor
```

---

### A.1.1 Defense Layers

```
┌─────────────────────────────────────────────────────────────────┐
│                    4-LAYER DEFENSE MODEL                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  LAYER 1: EDGE (Cloudflare)                                     │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ DDoS Protection │ WAF │ Bot Management │ SSL/TLS            ││
│  └─────────────────────────────────────────────────────────────┘│
│                              │                                   │
│                              ▼                                   │
│  LAYER 2: NETWORK (NPM + VPN + Firewall)                        │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ Nginx Proxy Manager │ WireGuard VPN │ UFW │ Cloud Firewall  ││
│  └─────────────────────────────────────────────────────────────┘│
│                              │                                   │
│                              ▼                                   │
│  LAYER 3: AUTH (Authelia)                                       │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ Forward Auth │ 2FA/TOTP │ OIDC Provider │ Session Mgmt      ││
│  └─────────────────────────────────────────────────────────────┘│
│                              │                                   │
│                              ▼                                   │
│  LAYER 4: APPLICATION (Container Isolation)                     │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ Docker Networks │ Read-only FS │ Non-root │ Secrets Mgmt    ││
│  └─────────────────────────────────────────────────────────────┘│
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

#### Network Configuration

| Layer | Component | Configuration |
|-------|-----------|---------------|
| Edge | Cloudflare | Proxied DNS, SSL Full Strict |
| Network | NPM | Reverse proxy on gcp-f-micro_1 |
| Network | Firewall | 22, 80, 443, 81 (admin) |
| Network | VPN | WireGuard on oci-p-flex_1 |
| Auth | Authelia | Forward auth on port 9091 |

---

### A.1.2 Security Monitors

#### Sauron SIEM

> [!abstract] Sauron
> Lightweight intrusion detection with YARA rules

| Component | Purpose | Location |
|-----------|---------|----------|
| **File Scanner** | YARA-based malware detection | All VMs |
| **Log Watcher** | Suspicious pattern detection | Centralized |
| **Alert System** | Email/webhook notifications | gcp-f-micro_1 |

#### YARA Rules Categories

```
sauron/rules/
├── webshells.yar      # PHP/ASP backdoors
├── cryptominers.yar   # Mining malware
├── ransomware.yar     # Encryption malware
├── rootkits.yar       # System compromise
└── custom.yar         # Project-specific
```

---

## A.2 Data Architecture

> [!tip] Data Philosophy
> Distributed databases, centralized backups, consolidated logs

### A.2.0 Databases

| Service | Database | Type | Location | Backup |
|---------|----------|------|----------|--------|
| Mailu | SQLite | Embedded | oci-f-micro_1 | rclone |
| Matomo | MariaDB | Container | oci-f-micro_2 | rclone |
| Photoprism | MariaDB | Container | oci-p-flex_1 | rclone |
| Authelia | SQLite | Embedded | gcp-f-micro_1 | rclone |
| NPM | SQLite | Embedded | gcp-f-micro_1 | rclone |
| Flask API | SQLite | Embedded | gcp-f-micro_1 | rclone |
| Radicale | File-based | CalDAV | oci-p-flex_1 | rclone |

---

### A.2.1 Central Backups

#### Backup Strategy

```
┌─────────────────────────────────────────────────────────────────┐
│                     BACKUP ARCHITECTURE                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  VMs (Source)              rclone              Oracle Object     │
│  ┌──────────┐             ┌──────┐            ┌──────────────┐  │
│  │oci-micro1│────────────►│      │───────────►│              │  │
│  │oci-micro2│────────────►│Sync  │───────────►│  Bucket:     │  │
│  │gcp-micro1│────────────►│      │───────────►│  backups/    │  │
│  │oci-flex1 │────────────►│      │───────────►│              │  │
│  └──────────┘             └──────┘            └──────────────┘  │
│                                                                  │
│  Schedule: Daily at 03:00 UTC                                    │
│  Retention: 7 daily, 4 weekly, 12 monthly                        │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

#### Backup Paths

| VM | Source Path | Destination |
|----|-------------|-------------|
| oci-f-micro_1 | `/home/ubuntu/mailu/` | `oci://backups/mailu/` |
| oci-f-micro_2 | `/home/ubuntu/matomo/` | `oci://backups/matomo/` |
| gcp-f-micro_1 | `/home/diego/npm/` | `oci://backups/npm/` |
| oci-p-flex_1 | `/home/ubuntu/photoprism/` | `oci://backups/photoprism/` |

---

### A.2.2 Central Logs

#### Log Consolidation (Planned)

| Component | Purpose | Status |
|-----------|---------|--------|
| **Loki** | Log aggregation | DEV |
| **Promtail** | Log shipping agent | DEV |
| **Grafana** | Log visualization | DEV |

#### Current Logging

```bash
# Per-container logging
docker logs --tail 100 <container>

# Centralized view (planned)
# All logs → Promtail → Loki → Grafana
```

---

### A.2.3 Cloud API & MCP Layer

#### Flask API

| Endpoint | Method | Purpose | Auth |
|----------|--------|---------|------|
| `/api/status` | GET | VM/service status | API Key |
| `/api/ssh` | POST | Execute SSH command | API Key |
| `/api/logs` | GET | Container logs | API Key |
| `/api/metrics` | GET | Performance data | API Key |
| `/api/deploy` | POST | Trigger deployment | API Key |
| `/api/dns` | POST | Cloudflare DNS | API Key |

#### MCP Integration

```python
# Claude agent calls MCP tool
{
  "tool": "cloud_status",
  "parameters": {
    "vm": "oci-p-flex_1",
    "service": "photoprism"
  }
}

# API translates to SSH command
ssh ubuntu@84.235.234.87 "docker ps --filter name=photoprism"
```

---

## A.3 Cloud Control Center

> [!tip] Purpose
> Centralized infrastructure management via CLI and Web

### A.3.0 C3 CLI

#### C3 Commands

| Command | Purpose |
|---------|---------|
| `c3 topology` | Show VM/service topology |
| `c3 monitor` | Real-time health status |
| `c3 audit` | Security audit report |
| `c3 orchestrate` | Deploy/restart services |
| `c3 cost` | Cloud spend analysis |

#### C3 Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         C3 CLI                                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌────────┐│
│  │ Topology │ │ Monitor  │ │  Audit   │ │Orchestr. │ │  Cost  ││
│  └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘ └───┬────┘│
│       │            │            │            │           │      │
│       └────────────┴────────────┴────────────┴───────────┘      │
│                              │                                   │
│                              ▼                                   │
│                    ┌──────────────────┐                         │
│                    │   Cloud API      │                         │
│                    │  (Flask REST)    │                         │
│                    └────────┬─────────┘                         │
│                             │                                    │
│              ┌──────────────┼──────────────┐                    │
│              ▼              ▼              ▼                    │
│         ┌────────┐    ┌────────┐    ┌────────┐                 │
│         │  OCI   │    │  GCP   │    │Cloudfl.│                 │
│         │  API   │    │  API   │    │  API   │                 │
│         └────────┘    └────────┘    └────────┘                 │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

### A.3.1 Cloud Monitor Engine

> [!success] Live Monitoring
> Health status, performance metrics, Sauron IDS

| Metric | Source | Frequency |
|--------|--------|-----------|
| VM Health | OCI/GCP API | 1 min |
| Container Status | Docker API | 30 sec |
| CPU/RAM | Node Exporter | 15 sec |
| Disk Usage | Node Exporter | 1 min |
| Network | Node Exporter | 15 sec |
| Security Alerts | Sauron | Real-time |

---

### A.3.2 Cloud Debug Engine

> [!abstract] Debug Tools
> Topology tables, command library

#### Topology Tables

| Table | Purpose |
|-------|---------|
| VMs | Provider, IP, specs, status |
| Services | Container, port, health |
| Networks | Subnet, connected containers |
| Domains | DNS records, SSL status |

#### Command Library

| Category | Examples |
|----------|----------|
| **SSH** | Connect, execute, tunnel |
| **Docker** | ps, logs, exec, restart |
| **System** | df, top, netstat, journalctl |

---

### A.3.3 Cloud Audit Sync Engine

> [!abstract] Data Collection
> Automated infrastructure data collection and consolidation

| Collector | Data | Schedule |
|-----------|------|----------|
| VM Inventory | Specs, IPs, status | Hourly |
| Container State | Running, health, ports | 5 min |
| Log Aggregation | All container logs | Real-time |
| Cost Data | OCI/GCP billing | Daily |

---

### A.3.4 VM Infrastructure Matrix

| VM ID | Provider | IP | Specs | Services | Cost | Status |
|-------|----------|-----|-------|----------|------|--------|
| oci-f-micro_1 | Oracle | 130.110.251.193 | 1 OCPU, 1 GB | Mailu | $0 | ON |
| oci-f-micro_2 | Oracle | 129.151.228.66 | 1 OCPU, 1 GB | Matomo | $0 | ON |
| gcp-f-micro_1 | Google | 34.55.55.234 | e2-micro, 1 GB | NPM, Authelia, API | $0 | ON |
| oci-p-flex_1 | Oracle | 84.235.234.87 | 2 vCPU, 8 GB | Photoprism, Radicale | ~$5.50/mo | WAKE |

---

## A.4 Frontend Development

> [!tip] Purpose
> Cloud Portal website development

### A.4.0 Cloud Portal

| Property | Value |
|----------|-------|
| **URL** | https://cloud.diegonmarcos.com |
| **Hosting** | GitHub Pages |
| **Source** | `/home/diego/Documents/Git/front-Github_io/a_Cloud/cloud/` |

#### Pages

| Page | File | Purpose |
|------|------|---------|
| Landing | `index.html` | Animated splash, 5s redirect |
| Products | `products.html` | Service catalog, tree view |
| Cloud Control | `cloud_control.html` | Topology, Cost, Monitor tabs |
| Architecture | `architecture.html` | Visual diagrams |

---

### A.4.1 Build Stack

| Component | Technology |
|-----------|------------|
| **Language** | TypeScript (Strict) |
| **Styling** | Sass (ITCSS) |
| **Build** | esbuild + Sass CLI |
| **Output** | Single-file SPA (inline CSS/JS) |
| **Port** | :8006 |

#### Build Pipeline

```
TypeScript ──► esbuild ──► bundle.js ─┐
                                      ├──► Inline into HTML ──► dist/
Sass ──────► sass CLI ──► styles.css ─┘
```

---

### A.4.2 Folder Structure

```
a_Cloud/cloud/
├── 0.spec/                  # Documentation
├── 1.ops/
│   └── build.sh             # Build script
├── src_vanilla/             # Source [DEFAULT]
│   ├── scss/
│   │   ├── _variables.scss
│   │   ├── _base.scss
│   │   ├── components/
│   │   ├── pages/
│   │   └── main.scss
│   ├── typescript/
│   │   ├── main.ts
│   │   ├── types.ts
│   │   ├── theme-switcher.ts
│   │   ├── tree-view.ts
│   │   └── data-loader.ts
│   └── *.html               # Page templates
├── src_vue/                 # Vue 3 alternative
├── dist/                    # Production output
└── public/                  # Static assets
```

---

### A.4.3 Pages & Components

#### Theme System

| Theme | Description |
|-------|-------------|
| Blurred | Glass morphism (default) |
| Dark | High contrast |
| Minimalistic | Clean, reduced UI |

#### TypeScript Modules

| Module | Purpose |
|--------|---------|
| `main.ts` | Entry point, initialization |
| `theme-switcher.ts` | Theme toggle logic |
| `tree-view.ts` | Infrastructure tree |
| `data-loader.ts` | JSON data fetching |
| `service-handler.ts` | Service card actions |

---

# B. TECHNICAL DESIGN

> [!warning] Status: TBD
> Section to be completed - How to build each component

---

# C. ROADMAP

> [!tip] Purpose
> Deployment priority and current status

## C.0 Status Matrix

### Legend

| Status | Description | Color |
|--------|-------------|-------|
| **ON** | Running in production | Green |
| **DEV** | Under active development | Blue |
| **WAKE** | Wake-on-Demand | Cyan |
| **HOLD** | Paused/waiting | Yellow |
| **TBD** | Planned for future | Gray |

---

### Production Services (ON)

> [!success] Running Services

| Service | Domain | VM | Technology |
|---------|--------|-----|------------|
| Mailu Mail | mail.diegonmarcos.com | oci-f-micro_1 | Postfix + Dovecot + Roundcube |
| Matomo Analytics | analytics.diegonmarcos.com | oci-f-micro_2 | matomo:fpm-alpine + MariaDB |
| NPM Proxy | proxy.diegonmarcos.com | gcp-f-micro_1 | nginx-proxy-manager |
| Authelia 2FA | auth.diegonmarcos.com | gcp-f-micro_1 | authelia/authelia |
| Cloud Dashboard | cloud.diegonmarcos.com | GitHub Pages | Static HTML/CSS/JS |
| Flask API | api.diegonmarcos.com | gcp-f-micro_1 | Python Flask |

---

### Wake-on-Demand Services (WAKE)

> [!note] Dormant by Default

| Service | Domain | VM | Technology |
|---------|--------|-----|------------|
| Photoprism | photos.app.diegonmarcos.com | oci-p-flex_1 | photoprism + MariaDB |
| Radicale Calendar | cal.diegonmarcos.com | oci-p-flex_1 | docker-radicale |
| Syncthing | sync.diegonmarcos.com | oci-p-flex_1 | syncthing |
| Redis Cache | - | oci-p-flex_1 | redis:alpine |

---

### Under Development (DEV)

> [!warning] In Progress

| Service | Target | Category | Status |
|---------|--------|----------|--------|
| Chat Multi-Model | TensorDock | AI | Concept |
| WebIDE | TensorDock | AI | Concept |
| Feed (RSS) | TBD | Inbox | Concept |
| Drive & Suite | TBD | Object Files | Concept |
| Music Player | TBD | Media | Concept |
| VPN (WireGuard) | oci-p-flex_1 | Security | In Progress |
| MCP Tools | gcp-f-micro_1 | Developer | In Progress |
| Sauron SIEM | All VMs | Security | In Progress |
| C3 CLI | Local | Developer | In Progress |

---

### Roadmap Phases

| Phase | Focus | Services |
|-------|-------|----------|
| **Phase 1** | Core Infrastructure | NPM, Authelia, API ✓ |
| **Phase 2** | User Productivity | Mail ✓, Photos ✓, Calendar ✓ |
| **Phase 3** | Security | VPN, Sauron, Vault |
| **Phase 4** | AI | Open WebUI, MCP Tools |
| **Phase 5** | Media | Music, Videos |

---

# D. DEVOPS

> [!tip] Purpose
> How to operate and maintain the infrastructure

## D.0 SSH Access

```bash
# Oracle Micro 1 (Mail)
ssh -i ~/Documents/Git/LOCAL_KEYS/00_terminal/ssh/id_rsa ubuntu@130.110.251.193

# Oracle Micro 2 (Analytics)
ssh -i ~/Documents/Git/LOCAL_KEYS/00_terminal/ssh/id_rsa ubuntu@129.151.228.66

# GCloud Arch 1 (Proxy)
gcloud compute ssh arch-1 --zone=us-central1-a

# Oracle Flex 1 (Wake-on-Demand)
ssh -i ~/Documents/Git/LOCAL_KEYS/00_terminal/ssh/id_rsa ubuntu@84.235.234.87
```

## D.1 Docker Commands

```bash
# List containers
docker ps

# View logs
docker logs --tail 100 <container>

# Enter container
docker exec -it <container> bash

# Restart service
docker compose restart <service>

# Full rebuild
docker compose down && docker compose up -d
```

## D.2 Service Health Checks

```bash
# NPM API
curl -s http://localhost:81/api/nginx/proxy-hosts -H "Authorization: Bearer $TOKEN"

# Authelia
curl -s https://auth.diegonmarcos.com/api/health

# Matomo
curl -s https://analytics.diegonmarcos.com/matomo.php

# Photoprism
curl -s https://photos.app.diegonmarcos.com/api/v1/status
```

## D.3 Backup Commands

```bash
# Manual backup
rclone sync /home/ubuntu/mailu oci:backups/mailu --progress

# Verify backup
rclone ls oci:backups/

# Restore
rclone sync oci:backups/mailu /home/ubuntu/mailu-restore
```

## D.4 Wake-on-Demand (oci-p-flex_1)

```bash
# Start VM
oci compute instance action --action START --instance-id <OCID>

# Stop VM
oci compute instance action --action STOP --instance-id <OCID>

# Check status
oci compute instance get --instance-id <OCID> --query 'data."lifecycle-state"'
```

---

# X. APPENDIX

> [!abstract] Reference Materials
> Code practices, secrets management, technical research

## X.0 Technical Research

| Topic | Status | Notes |
|-------|--------|-------|
| WireGuard VPN | Researching | Config for oci-p-flex_1 |
| Loki/Grafana | Researching | Log aggregation stack |
| Open WebUI | Researching | Self-hosted ChatGPT |
| Vaultwarden | Researching | Self-hosted Bitwarden |

---

## X.1 Code Repository Structure

```
/home/diego/Documents/Git/
├── back-System/                    # Backend & Infrastructure
│   └── cloud/
│       ├── 0.spec/                 # Specifications
│       │   ├── v1/                 # Legacy specs
│       │   ├── v2/                 # Reference docs
│       │   └── v3/                 # Current (this doc)
│       ├── 1.ops/                  # Operations
│       │   ├── cloud_architecture.json
│       │   └── vm-control.sh
│       ├── a_solutions/            # Backend solutions
│       │   └── api/                # Flask API
│       └── b_infra/                # Infrastructure configs
│
├── front-Github_io/                # Frontend Projects
│   ├── a_Cloud/
│   │   └── cloud/                  # Cloud Portal
│   ├── b_Linktree/                 # Other projects
│   └── 1.ops/                      # Shared ops
│       ├── deploy.yml              # GitHub Actions
│       ├── build_main.sh           # Master builder
│       └── 30_Code_Practise.md     # Code standards
│
└── LOCAL_KEYS/                     # Credentials (never commit)
    ├── vault.json                  # Source of truth
    └── 00_terminal/                # CLI configs
```

---

## X.2 Secrets & Access Management

**Source:** `LOCAL_KEYS/SPEC.md`

### X.2.0 Architecture

```
vault.json = SOURCE OF TRUTH
     │
     └──► build.py ──► exports/ (Bitwarden, Brave, CSV)
```

---

### X.2.1 Folder Structure

```
LOCAL_KEYS/
├── vault.json              ← Source of truth
├── build.py                ← Export script
├── 00_terminal/
│   ├── ssh/                # SSH keys
│   ├── oracle/             # OCI CLI
│   ├── gcloud/             # GCloud CLI
│   └── github/             # GitHub CLI
├── 02_browser/
│   ├── bitwarden_api.json
│   └── totp/aegis_vault.json
└── exports/                # Generated (gitignored)
```

---

### X.2.2 Data Inventory

| Category | Count |
|----------|-------|
| Passwords | 1,127 |
| Folders | 15 |
| Identities | 3 |
| Cards | 1 |
| TOTP | 30 |

---

### X.2.3 Security Stack

| Layer | Tool |
|-------|------|
| Browser | Bitwarden Extension |
| 2FA | Aegis + Garmin |
| Passkeys | Phone + YubiKey Bio |
| SSH | ssh-agent + keys |
| Cloud CLI | OCI + GCloud configs |

---

### X.2.4 VM SSH Quick Reference

| Alias | VM | IP | Command |
|-------|-----|-----|---------|
| flex1 | oci-p-flex_1 | 84.235.234.87 | `ssh -i .../id_rsa ubuntu@84.235.234.87` |
| micro1 | oci-f-micro_1 | 130.110.251.193 | `ssh -i .../id_rsa ubuntu@130.110.251.193` |
| micro2 | oci-f-micro_2 | 129.151.228.66 | `ssh -i .../id_rsa ubuntu@129.151.228.66` |
| arch-1 | gcp-f-micro_1 | 34.55.55.234 | `gcloud compute ssh arch-1 --zone=us-central1-a` |

---

### X.2.5 Cloud Credentials

| Service | Location |
|---------|----------|
| Oracle Cloud | 00_terminal/oracle/ |
| Google Cloud | 00_terminal/gcloud/ |
| Cloudflare | vault.json |
| NPM | vault.json |
| Authelia | vault.json |

---

### X.2.6 Backup Strategy

| Layer | Method | Frequency |
|-------|--------|-----------|
| vault.json | Syncthing | Real-time |
| Bitwarden | Cloud sync | Daily |
| Aegis | Phone backup | Auto |
| Cold Storage | Encrypted archive | Monthly |

---

### X.2.7 Export Commands

```bash
python build.py              # Show stats
python build.py bitwarden    # Bitwarden import
python build.py brave        # Brave/Chrome import
python build.py csv          # Organized CSVs
python build.py all          # All formats
```

---

## X.3 Frontend Practices

### X.3.0 CI/CD Pipeline

**Source:** `1.ops/deploy.yml`

| Component | Value |
|-----------|-------|
| **Trigger** | Push to `main` |
| **Platform** | GitHub Actions → GitHub Pages |
| **Strategy** | Incremental (only changed projects) |
| **Node** | v20 |

**Pipeline:** `Push → Detect Changes → Build → Prepare _site/ → Deploy`

---

### X.3.1 Build System & DevOps

**Source:** `1.ops/20_a_DevOps.md`

#### Main Orchestrator

```bash
./1.ops/build_main.sh              # Interactive TUI
./1.ops/build_main.sh build        # Build all
./1.ops/build_main.sh dev          # Start all dev servers
./1.ops/build_main.sh build-cloud  # Build specific
./1.ops/build_main.sh dev-cloud    # Dev server specific
./1.ops/build_main.sh kill         # Kill all servers
```

#### Port Assignments

| Port | Project | Framework |
|------|---------|-----------|
| :8000 | Landpage | Vanilla |
| :8001 | Linktree | Vanilla |
| :8002 | CV Web | Vanilla |
| :8003 | MyFeed | Vue 3 |
| :8004 | MyGames | SvelteKit |
| :8005 | Nexus | Vanilla |
| :8006 | Cloud | Vanilla |

---

### X.3.2 Code Practices

**Source:** `1.ops/30_Code_Practise.md`

#### HTML Standards

- Semantic tags: `<header>`, `<nav>`, `<main>`, `<section>`, `<footer>`
- `<a>` for navigation, `<button>` for actions
- All `<img>` must have `alt`

#### SCSS Golden Mixins

```scss
@include mq(sm|md|lg|xl)              // Breakpoints
@include flex-center;                  // Center anything
@include flex-row(justify, align, gap);
@include flex-col(justify, align, gap);
@include grid-auto-fit(min-size, gap);
```

#### TypeScript Rules

- Strict mode: No `any`
- DOM: Cast elements, null checks
- ES Modules: `import`/`export`

#### Framework Rules

| Framework | Syntax |
|-----------|--------|
| **Vue 3** | `<script setup lang="ts">` |
| **Svelte 5** | Runes: `$state()`, `$derived()`, `$props()` |

---

### X.3.3 Analytics (Matomo)

**Source:** `1.ops/01_Analytics.md`

| Setting | Value |
|---------|-------|
| **Server** | analytics.diegonmarcos.com |
| **Container** | `container_odwLIyPV.js` |
| **Privacy** | Cookie-less, GDPR-compliant |

**Required Header:**

```html
<script>
var _mtm = window._mtm = window._mtm || [];
_mtm.push({'mtm.startTime': (new Date().getTime()), 'event': 'mtm.Start'});
(function() {
  var d=document, g=d.createElement('script'), s=d.getElementsByTagName('script')[0];
  g.async=true; g.src='https://analytics.diegonmarcos.com/js/container_odwLIyPV.js';
  s.parentNode.insertBefore(g,s);
})();
</script>
```

---

> [!info] Document End
> **Last Updated:** 2025-12-26
> **Maintainer:** Diego Nepomuceno Marcos
