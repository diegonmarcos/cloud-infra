# Cloud Portal

> Infrastructure & AI Management

---

## Table of Contents

- [User](#user-products) | [Cloud Control](#cloud-control) | [Architecture](#architecture)

---

# User (Products)

## Products | Connect | Features

---

## Products Tab

### AI

| Service | Description | Status |
|---------|-------------|--------|
| **Chat Multi-Model** | Multi-provider AI Chat | `dev` |
| **WebIDE** | AI powered Terminal File Explorer and IDE | `dev` |

### Inbox

| Service | Description | URL | Status |
|---------|-------------|-----|--------|
| **Mail&Cal** | mymail landing | [diegonmarcos.github.io/mymail](https://diegonmarcos.github.io/mymail) | `on` |
| **Feed** | RSS / News aggregator | - | `dev` |

### Object Files

| Service | Description | URL | Status |
|---------|-------------|-----|--------|
| **Photos** | myphotos landing | [diegonmarcos.github.io/myphotos](https://diegonmarcos.github.io/myphotos) | `on` |
| **Drive&Suite** | Documents Storage and Office Suite | - | `dev` |

### Media

| Service | Description | Status |
|---------|-------------|--------|
| **Music** | Navidrome / Jellyfin | `dev` |
| **Videos&Movies** | Jellyfin / Plex | `dev` |

### Me

| Service | Description | URL | Status |
|---------|-------------|-----|--------|
| **Linktree** | diegonmarcos.github.io/linktree | [diegonmarcos.github.io/linktree](https://diegonmarcos.github.io/linktree) | `on` |
| **Maps** | Maps, Transport | - | `dev` |

---

## Connect Tab

### Cloud

| Service | Description | URL | Status |
|---------|-------------|-----|--------|
| **Cloud App** | Cloud Dashboard | [diegonmarcos.github.io/cloud](https://diegonmarcos.github.io/cloud) | `on` |

### Security

| Service | Description | Status |
|---------|-------------|--------|
| **VPN** | WireGuard VPN | `dev` |
| **Vault** | Bitwarden / Vaultwarden | `dev` |

### Developer

| Service | Description | URL | Status |
|---------|-------------|-----|--------|
| **API Endpoints** | REST API Documentation | /cloud/api | `dev` |
| **MCP Tools** | Model Context Protocol | /cloud/mcp | `dev` |

---

## Features Tab

### Summary

| Metric | Value |
|--------|-------|
| VMs | 4 |
| Services | 20+ |
| Cloud Providers | 2 |
| Uptime | 24/7 |

### Portal Features

| Feature | Description | Status |
|---------|-------------|--------|
| Multi-page Navigation | Products, Cloud Control, Architecture views | ✓ |
| Theme System | Blurred, Dark, Minimalistic modes with persistence | ✓ |
| Category Filtering | AI, Productivity, Media, Me, City, Cloud Connect | ✓ |
| Responsive Design | Mobile-first, works on all screen sizes | ✓ |
| Single-File Build | CSS/JS inlined, no external dependencies | ✓ |
| Offline Capable | Works without network after first load | ✓ |

### Infrastructure

| Component | Description | Status |
|-----------|-------------|--------|
| Oracle Cloud VMs | 3 instances (2x Micro, 1x Flex A1) | ✓ |
| Google Cloud VMs | 1 instance (e2-micro) | ✓ |
| Nginx Proxy Manager | Reverse proxy with SSL certificates | ✓ |
| Authelia 2FA | Two-factor authentication gateway | ✓ |
| Cloudflare DNS | DNS management with proxy protection | ✓ |
| Docker Networks | Isolated container networks per VM | ✓ |

### Backend Services

**Core Services**
- ✓ Flask REST API
- ✓ Redis Cache
- ✓ SQLite Database
- ✓ MariaDB

**Mail Services**
- ✓ Mailu SMTP/IMAP
- ✓ Roundcube Webmail
- ✓ Rspamd Anti-Spam
- ✓ ClamAV Antivirus

**Media & Storage**
- ✓ Photoprism Gallery
- ✓ Radicale CalDAV
- ○ Vaultwarden

### Analytics & Monitoring

| Service | Description | Status |
|---------|-------------|--------|
| Matomo Analytics | Privacy-first, GDPR compliant web analytics | ✓ |
| n8n Automation | Workflow automation and integrations | ○ |
| Health Checks API | Real-time service status monitoring | ✓ |

### Comparison: Self-Hosted vs Big Cloud

| Feature | This Portal | Google Cloud | AWS |
|---------|-------------|--------------|-----|
| Monthly Cost | **~$5.50** | $50-200+ | $50-200+ |
| Data Privacy | ✓ Full Control | Shared | Shared |
| Email Service | ✓ Self-hosted | $6/user/mo | SES only |
| Photo Storage | ✓ Unlimited | 15GB free | S3 costs |
| Analytics | ✓ GDPR Ready | GA4 (tracks) | - |
| 2FA Auth | ✓ Authelia | ✓ | ✓ |
| Vendor Lock-in | ✓ None | High | High |

---

## Status Tree

### IaaS - Self-Hosted VPS

```
Google Cloud [dev]
├── [CLI] gcloud [on]
└── VM: GCloud_microe2Linux_1 [dev]
    ├── Services
    │   ├── mail-app [dev]
    │   ├── terminal-app [dev]
    │   └── npm-gcloud [dev]
    ├── Data
    │   └── mail-db [dev]
    └── OS: Arch Linux (us-central1-a)
        ├── Docker Networks: bridge
        └── HD Partitions: / (10GB)

Oracle Cloud [on]
├── [CLI] oci [on]
├── VM: Oracle_Web_Server_1 [on]
│   │   IP: 130.110.251.193
│   ├── Services
│   │   ├── cloud-app [on]
│   │   ├── n8n-infra-app [on]
│   │   ├── cloud-api [on]
│   │   ├── npm-oracle-web [on]
│   │   ├── git-app [dev]
│   │   ├── vpn-app [dev]
│   │   └── cache-app [hold]
│   ├── Data
│   │   ├── n8n-infra-db [on]
│   │   └── git-db [dev]
│   └── OS: Ubuntu 22.04
│
├── VM: Oracle_Services_Serv [on]
│   │   IP: 129.151.228.66
│   ├── Services
│   │   ├── analytics-app [on]
│   │   └── npm-oracle-services [on]
│   ├── Data
│   │   ├── analytics-db [on]
│   │   └── cloud-db [dev]
│   └── OS: Ubuntu 22.04
│
└── VM: oci-p-flex_1 [wake]
    │   IP: 84.235.234.87
    ├── Services
    │   ├── photoprism-app
    │   ├── radicale-app
    │   └── redis
    ├── Data
    │   └── photoprism-db
    └── OS: Ubuntu 22.04 Minimal

Generic VPS [tbd]
└── VM: Generic_Infra [tbd]
    └── (placeholder for future expansion)
```

---

# Cloud Control

## Topology | Monitor & Audit | Orchestrate | Cost | Apps

---

## Topology Tab

### Sub-tabs: App | Data | Containers | Security

---

## Monitor & Audit Tab

### Sub-tabs: Infra | Security | Analytics | Logs

### VM Overview

| Mode | Host | VM | IP | Status | Actions |
|------|------|----|----|--------|---------|
| 24/7 | Oracle | OCI Paid Flex 1 | 84.235.234.87 | `wake` | Start/Stop |
| 24/7 | Oracle | Oracle Web Server 1 | 130.110.251.193 | `on` | - |
| 24/7 | Oracle | Oracle Services Server 1 | 129.151.228.66 | `on` | - |
| 24/7 | GCloud | GCloud Arch 1 | 34.55.55.234 | `on` | - |

### Service Breakdown by VM

| Status | Service | Domain | Port | RAM | Storage | Health |
|--------|---------|--------|------|-----|---------|--------|
| `ON` | Matomo | analytics.diegonmarcos.com | :8080 | 512MB-1GB | 3-15GB | Healthy |
| `ON` | NPM | - | :80,:443,:81 | 512MB-1GB | 400MB-2GB | Healthy |
| `ON` | n8n (Infra) | n8n.diegonmarcos.com | :5678 | 256-512MB | 500MB-2GB | Healthy |
| `ON` | Flask Server | cloud.diegonmarcos.com | :5000 | 64-128MB | 50-100MB | Healthy |
| `DEV` | Mailu Mail Suite | mail.diegonmarcos.com | - | 1-2GB | 5-50GB | Dev |
| `DEV` | OpenVPN | - | :1194 | 64-128MB | 50-100MB | Dev |
| `DEV` | Web Terminal | terminal.diegonmarcos.com | :7681 | 64-128MB | 50-100MB | Dev |
| `DEV` | Gitea | git.diegonmarcos.com | :3000 | 264-544MB | 11-15GB | Dev |
| `HOLD` | Redis | - | :6379 | 64-256MB | 100MB-1GB | Hold |

### Backlog (DEV/HOLD)

| Service | Status | VM | Notes |
|---------|--------|-----|-------|
| Mailu Mail Suite | DEV | GCloud Arch 1 | 8-container mail suite |
| OpenVPN | DEV | Oracle Web Server 1 | VPN server |
| Gitea | DEV | Oracle Web Server 1 | Git hosting |
| Redis | HOLD | Oracle Web Server 1 | In-memory store |

---

## Orchestrate Tab

### Docker Container Management

Quick Actions:
- Start All Containers
- Stop All Containers
- Restart NPM
- View Logs

---

## Cost Tab

### Sub-tabs: Infrastructure | AI Costs

### Provider Cost Distribution (Current Month)

| Provider | Tier | Monthly Cost |
|----------|------|--------------|
| Oracle Cloud | Free Tier | $0.00 |
| Oracle Cloud | Paid (Flex) | $5.50 |
| Google Cloud | Free Tier | $0.00 |
| Cloudflare | Free | $0.00 |
| **Total** | | **$5.50/mo** |

### Resource Usage by VM

| VM | CPU | RAM (Total) | RAM (Used) | Storage | Bandwidth |
|----|-----|-------------|------------|---------|-----------|
| OCI Flex 1 | 2 vCPU | 8 GB | 6.5 GB | 100 GB | 10 TB |
| OCI Micro 1 | 1 vCPU | 1 GB | 850 MB | 47 GB | 10 TB |
| OCI Micro 2 | 1 vCPU | 1 GB | 700 MB | 47 GB | 10 TB |
| GCP Micro 1 | 1 vCPU | 1 GB | 576 MB | 30 GB | 1 GB/mo |

### Free Tier Utilization

| Resource | Limit | Used | % |
|----------|-------|------|---|
| OCI Compute | 2 Always Free VMs | 2 | 100% |
| OCI Storage | 200 GB | 94 GB | 47% |
| OCI Bandwidth | 10 TB/mo | ~50 GB | <1% |
| GCP Compute | 1 e2-micro | 1 | 100% |
| GCP Egress | 1 GB/mo | ~500 MB | 50% |

### AI Costs

| Model | Provider | Input ($/M) | Output ($/M) | Daily Cost |
|-------|----------|-------------|--------------|------------|
| Claude Opus | Anthropic | $15.00 | $75.00 | ~$0.50 |
| Claude Sonnet | Anthropic | $3.00 | $15.00 | ~$0.20 |
| GPT-4o | OpenAI | $5.00 | $15.00 | ~$0.10 |
| GPT-4o-mini | OpenAI | $0.15 | $0.60 | ~$0.02 |

---

## Apps Tab

### Cloud Management Applications

| App | URL | Description |
|-----|-----|-------------|
| NPM Dashboard | proxy.diegonmarcos.com | Nginx Proxy Manager |
| Matomo | analytics.diegonmarcos.com | Web Analytics |
| Authelia | auth.diegonmarcos.com | 2FA Portal |
| n8n | n8n.diegonmarcos.com | Workflow Automation |

---

# Architecture

## Infra | Data | Security | AI

---

## Infra Tab

### Infrastructure Architecture v2.0

*Multi-Cloud Topology - GCP + Oracle Cloud + Cloudflare*

```
                         ┌─────────┐
                         │  USER   │
                         └────┬────┘
                              │
                              ▼
                    ┌─────────────────┐
                    │   CLOUDFLARE    │
                    │  DNS + CDN +    │
                    │ DDoS Protection │
                    └────────┬────────┘
                             │
                             ▼
              ┌──────────────────────────────┐
              │     GOOGLE CLOUD (Gateway)   │
              │      gcp-f-micro_1 FREE      │
              │        34.55.55.234          │
              │  ┌─────┐ ┌───────┐ ┌──────┐  │
              │  │ NPM │ │Authelia│ │OAuth2│ │
              │  │:80  │ │ :9091  │ │:4180 │  │
              │  └──┬──┘ └───┬───┘ └──┬───┘  │
              └─────┼────────┼────────┼──────┘
                    │        │        │
       ┌────────────┼────────┼────────┼────────────┐
       │            ▼        ▼        ▼            │
       │        ORACLE CLOUD (Services)            │
       │                                           │
       │ ┌────────────┐ ┌────────────┐ ┌─────────────────────┐
       │ │oci-f-micro1│ │oci-f-micro2│ │   oci-p-flex_1      │
       │ │   FREE     │ │   FREE     │ │   $5.50/mo          │
       │ │ 1GB RAM    │ │ 1GB RAM    │ │   8GB RAM           │
       │ │130.110...  │ │129.151...  │ │   84.235.234.87     │
       │ │            │ │            │ │                     │
       │ │ ┌────────┐ │ │ ┌────────┐ │ │ ┌───────┐ ┌───────┐ │
       │ │ │ MAIL   │ │ │ │MATOMO  │ │ │ │FRIDGE │ │KITCHEN│ │
       │ │ │8 cont. │ │ │ │Analytics│ │ │ │Photos │ │ C3    │ │
       │ │ └────────┘ │ │ └────────┘ │ │ │Sync   │ │ API   │ │
       │ └────────────┘ └────────────┘ │ │Cal    │ │ Redis │ │
       │                               │ └───────┘ └───────┘ │
       │                               └─────────────────────┘
       └───────────────────────────────────────────────────────┘
```

### VM Capacity & Headroom

| Host | VM | IP | RAM | Alloc | Headroom | Services |
|------|----|----|-----|-------|----------|----------|
| GCloud | gcp-f-micro_1 | 34.55.55.234 | 1 GB | 576 MB | 42% | proxy, authelia, oauth2, api |
| Oracle | oci-f-micro_1 | 130.110.251.193 | 1 GB | 850 MB | 15% | mail (8 containers) |
| Oracle | oci-f-micro_2 | 129.151.228.66 | 1 GB | 700 MB | 30% | matomo, mariadb |
| Oracle | oci-p-flex_1 | 84.235.234.87 | 8 GB | 6.5 GB | 19% | fridge, kitchen, redis |

---

## Data Tab

### Database Allocations by VM

| VM | Database | Type | Size | Purpose |
|----|----------|------|------|---------|
| oci-f-micro_2 | matomo_db | MariaDB | 3-15 GB | Analytics |
| oci-p-flex_1 | photoprism_db | SQLite | 1-5 GB | Photo metadata |
| gcp-f-micro_1 | authelia_db | SQLite | 50 MB | Auth sessions |

### MCP Tools

| Tool | Description | Status |
|------|-------------|--------|
| Cloud API | REST endpoints for infra | `on` |
| VM Control | Start/stop VMs | `dev` |
| DNS Manager | Cloudflare integration | `dev` |

---

## Security Tab

### Security Architecture v2.1

*Defense in Depth - OIDC Passwordless Front Gate (GitHub SSO + TOTP + Passkey + VPN)*

### 1) Secure VPS Architecture

*Single VPS Security Model - Network Isolation & Container Hardening*

#### Traffic Types

| Type | Protocol | Allowed |
|------|----------|---------|
| HTTP/HTTPS | Web | ✓ |
| SSH | Admin | ✓ (Restricted IPs) |
| SMTP/IMAP | Mail | ✓ |
| All Other | - | ✗ Blocked |

#### Security Layers

```
┌─────────────────────────────────────────┐
│              INTERNET                    │
│    HTTP/HTTPS    SSH    SMTP/IMAP       │
└──────────────────┬──────────────────────┘
                   ▼
┌─────────────────────────────────────────┐
│         CLOUD FIREWALL                   │
│   OCI Security Lists / GCP Firewall     │
│   Ingress: 80, 443, 22, 25, 465, 587    │
└──────────────────┬──────────────────────┘
                   ▼
┌─────────────────────────────────────────┐
│            HOST FIREWALL                 │
│               UFW                        │
│         Port-level control              │
└──────────────────┬──────────────────────┘
                   ▼
┌─────────────────────────────────────────┐
│          REVERSE PROXY                   │
│      Nginx Proxy Manager                 │
│   SSL Termination + Routing             │
└──────────────────┬──────────────────────┘
                   ▼
┌─────────────────────────────────────────┐
│        CONTAINER NETWORK                 │
│      Docker Bridge Networks              │
│   172.20.0.0/24, 172.21.0.0/24, etc    │
└──────────────────┬──────────────────────┘
                   ▼
┌─────────────────────────────────────────┐
│          APPLICATIONS                    │
│      Per-container hardening            │
└─────────────────────────────────────────┘
```

### 2) Cloud Security Architecture

*Multi-Factor Authentication Flow*

#### Auth Stack

| Layer | Method | Provider |
|-------|--------|----------|
| Primary Auth | GitHub SSO | OIDC |
| 2FA | TOTP | Aegis Authenticator |
| Passkey | WebAuthn | Browser native |
| Network Auth | WireGuard VPN | Self-hosted |
| Session | Authelia Cookies | JWT |

#### Authentication Flow

```
┌─────────┐
│  USER   │
└────┬────┘
     │
     ▼
┌─────────────────┐
│  GitHub SSO     │
│    (OIDC)       │
└────────┬────────┘
         │
         ▼
┌─────────────────┐     ┌──────────────┐
│  Authelia 2FA   │────▶│ TOTP Code    │
│                 │     │ (Aegis App)  │
│                 │     ├──────────────┤
│                 │     │   OR         │
│                 │────▶│ Passkey      │
│                 │     │ (WebAuthn)   │
└────────┬────────┘     └──────────────┘
         │
         ▼
┌─────────────────┐
│ Session Cookie  │
│    (JWT)        │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   Protected     │
│    Service      │
└─────────────────┘
```

#### SSO Across Subdomains

All services under `*.diegonmarcos.com` share authentication:

- analytics.diegonmarcos.com
- photos.app.diegonmarcos.com
- n8n.diegonmarcos.com
- proxy.diegonmarcos.com
- auth.diegonmarcos.com
- sync.diegonmarcos.com
- cal.diegonmarcos.com

### Public Ports Audit

| Port | Service | VM | Exposure |
|------|---------|-----|----------|
| 80 | HTTP | All | Public (→ HTTPS redirect) |
| 443 | HTTPS | All | Public |
| 22 | SSH | All | Restricted IPs |
| 81 | NPM Admin | GCP | Behind Authelia |
| 25/465/587 | SMTP | OCI Micro 1 | Public |
| 993 | IMAPS | OCI Micro 1 | Public |

### Docker Network Segmentation

| VM | Network | Subnet | Containers |
|----|---------|--------|------------|
| oci-f-micro_1 | mail_network | 172.20.0.0/24 | mailu-* (8) |
| oci-f-micro_2 | matomo_network | 172.21.0.0/24 | matomo, mariadb |
| gcp-f-micro_1 | proxy_network | 172.23.0.0/24 | npm, authelia, oauth2 |
| oci-p-flex_1 | dev_network | 172.24.0.0/24 | photoprism, syncthing, radicale |

---

## AI Tab

### AI Architecture

#### Model Routing

| Use Case | Model | Provider |
|----------|-------|----------|
| Complex reasoning | Claude Opus | Anthropic |
| General tasks | Claude Sonnet | Anthropic |
| Fast responses | GPT-4o-mini | OpenAI |
| Code generation | Claude Sonnet | Anthropic |

#### API Gateway

```
┌─────────────┐
│   Client    │
└──────┬──────┘
       │
       ▼
┌─────────────────┐
│  Flask API      │
│  (cloud.diegon  │
│   marcos.com)   │
└────────┬────────┘
         │
    ┌────┴────┐
    ▼         ▼
┌───────┐ ┌───────┐
│Anthropic│ │OpenAI │
│  API   │ │  API  │
└───────┘ └───────┘
```

#### Token Tracking

| Metric | Value |
|--------|-------|
| Daily Input Tokens | ~50K |
| Daily Output Tokens | ~20K |
| Monthly Cost | ~$25 |

---

# Status Badges Legend

| Badge | Meaning | Color |
|-------|---------|-------|
| `on` | Running and accessible | 🟢 Green |
| `dev` | Under active development | 🔵 Blue |
| `wake` | Wake-on-Demand (dormant by default) | 🔷 Cyan |
| `hold` | Waiting for resources | 🟡 Yellow |
| `tbd` | Planned for future | ⚪ Gray |

---

# Theme System

| Theme | Description |
|-------|-------------|
| **Blurred** (default) | Glass morphism effects with backdrop blur |
| **Dark** | High contrast dark mode |
| **Minimalistic** | Clean, reduced UI |

---

*Cloud Portal - https://cloud.diegonmarcos.com*
