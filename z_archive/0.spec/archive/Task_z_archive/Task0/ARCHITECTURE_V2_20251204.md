# Cloud Infrastructure Architecture v2.0

**Date**: 2025-12-04
**Status**: APPROVED
**Author**: Diego (CEO) + Claude (Architect)

---

## Executive Summary

Optimized multi-cloud architecture with:
- **3 Free-Tier VMs** running 24/7 for critical services
- **1 Paid Dormant VM** with wake-on-demand for dev services
- **Single NPM** as central reverse proxy
- **Total Cost**: ~$5-7/month

---

## Infrastructure Overview

```
                            INTERNET
                               │
                               ▼
                    ┌─────────────────────┐
                    │   GCloud Arch 1     │
                    │   (US - Free Tier)  │
                    │                     │
                    │   NPM (24/7)        │
                    │   ~200MB RAM        │
                    └──────────┬──────────┘
                               │
           ┌───────────────────┼───────────────────┐
           │                   │                   │
           ▼                   ▼                   ▼
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────────┐
│ Oracle Web 1    │ │ Oracle Svc 1    │ │ Oracle E4.Flex 8GB  │
│ (EU - Free)     │ │ (EU - Free)     │ │ (EU - Paid Dormant) │
│                 │ │                 │ │                     │
│ Mail Server     │ │ Matomo App      │ │ n8n (Infra)         │
│ Mail DB         │ │ Matomo DB       │ │ Syncthing           │
│                 │ │                 │ │ Gitea               │
│ ~550MB-1GB      │ │ ~512MB-1GB      │ │ Cloud Dashboard     │
│                 │ │                 │ │ Cloud API           │
└─────────────────┘ └─────────────────┘ │ Web Terminal        │
                                        │ VPN                 │
                                        │ Redis Cache         │
                                        │                     │
                                        │ ~1.2-2GB used       │
                                        │ (8GB available)     │
                                        └─────────────────────┘
```

---

## VM Specifications

### GCloud Arch 1 (Free Tier - 24/7)

| Attribute | Value |
|-----------|-------|
| **Provider** | Google Cloud |
| **Region** | us-central1 |
| **Instance Type** | e2-micro |
| **vCPU** | 0.25-2 (shared) |
| **RAM** | 1 GB |
| **Storage** | 30 GB |
| **Monthly Cost** | $0 (Free Tier) |
| **Role** | Central Reverse Proxy |

**Services:**
| Service | RAM | Port | Status |
|---------|-----|------|--------|
| NPM | 128-256MB | 80, 443, 81 | 24/7 |

---

### Oracle Web Server 1 (Free Tier - 24/7)

| Attribute | Value |
|-----------|-------|
| **Provider** | Oracle Cloud |
| **Region** | eu-marseille-1 |
| **Instance Type** | VM.Standard.E2.1.Micro |
| **vCPU** | 2 (1 OCPU) |
| **RAM** | 1 GB |
| **Storage** | 47 GB |
| **Public IP** | 130.110.251.193 |
| **Monthly Cost** | $0 (Always Free) |
| **Role** | Mail Services |

**Services:**
| Service | RAM | Port | Status |
|---------|-----|------|--------|
| Mail Server | 512MB-1GB | 25, 587, 993 | 24/7 |
| Mail DB | 8-32MB | - | 24/7 |
| **Total** | 520MB-1GB | | |

---

### Oracle Services Server 1 (Free Tier - 24/7)

| Attribute | Value |
|-----------|-------|
| **Provider** | Oracle Cloud |
| **Region** | eu-marseille-1 |
| **Instance Type** | VM.Standard.E2.1.Micro |
| **vCPU** | 2 (1 OCPU) |
| **RAM** | 1 GB |
| **Storage** | 47 GB |
| **Public IP** | 129.151.228.66 |
| **Monthly Cost** | $0 (Always Free) |
| **Role** | Analytics Services |

**Services:**
| Service | RAM | Port | Status |
|---------|-----|------|--------|
| Matomo App | 256-512MB | 8080 | 24/7 |
| Matomo DB | 256-512MB | 3306 | 24/7 |
| **Total** | 512MB-1GB | | |

---

### Oracle E4.Flex 8GB (Paid - Dormant/Wake-on-Demand)

| Attribute | Value |
|-----------|-------|
| **Provider** | Oracle Cloud |
| **Region** | eu-marseille-1 |
| **Instance Type** | VM.Standard.E4.Flex |
| **Configuration** | 1 OCPU + 8GB RAM |
| **vCPU** | 2 |
| **RAM** | 8 GB |
| **Storage** | 100 GB (Block Volume) |
| **Public IP** | Elastic (assigned) |
| **Hourly Cost** | ~$0.037/hour |
| **Monthly Cost** | ~$5-7 (120-200h usage) |
| **Role** | Development Services |
| **Availability** | Wake-on-Demand |
| **Idle Timeout** | 15-30 minutes |
| **Wake Time** | ~45-60 seconds |

**Services:**
| Service | RAM | Port | Wake Trigger |
|---------|-----|------|--------------|
| n8n (Infra) | 256-512MB | 5678 | HTTP request |
| Syncthing | 128-256MB | 8384, 22000 | HTTP/Schedule |
| Gitea | 256-512MB | 3000, 2222 | HTTP request |
| Cloud Dashboard | - | 443 | HTTP request |
| Cloud API | 64-128MB | 5000 | HTTP request |
| Web Terminal | 64-128MB | 8080 | HTTP request |
| VPN | 64-128MB | 1194 | Manual |
| Redis Cache | 64-256MB | 6379 | With services |
| **Total** | 1.2-2GB | | |

---

## Domain Routing (NPM Configuration)

| Domain | Target VM | Target Port | Wake? |
|--------|-----------|-------------|-------|
| `analytics.diegonmarcos.com` | Oracle Services 1 | 8080 | No (24/7) |
| `mail.diegonmarcos.com` | Oracle Web 1 | 25/587/993 | No (24/7) |
| `sync.diegonmarcos.com` | Oracle Paid 8GB | 8384 | Yes |
| `n8n.diegonmarcos.com` | Oracle Paid 8GB | 5678 | Yes |
| `git.diegonmarcos.com` | Oracle Paid 8GB | 3000 | Yes |
| `cloud.diegonmarcos.com` | Oracle Paid 8GB | 5000 | Yes |
| `terminal.diegonmarcos.com` | Oracle Paid 8GB | 8080 | Yes |

---

## Wake-on-Demand System

### Architecture

```
User Request → NPM (GCloud)
                    │
                    ├── Check: Is target VM running?
                    │   │
                    │   ├── YES → Proxy request normally
                    │   │
                    │   └── NO → Trigger wake function
                    │            │
                    │            ▼
                    │       OCI Function (Free)
                    │            │
                    │            ▼
                    │       Start VM via OCI API
                    │            │
                    │            ▼
                    │       Return "Loading..." page
                    │            │
                    │            ▼
                    │       Auto-refresh (45-60s)
                    │            │
                    │            ▼
                    └────── Service ready
```

### Components

| Component | Provider | Cost | Purpose |
|-----------|----------|------|---------|
| NPM Health Check | GCloud | Free | Detect VM state |
| Wake Function | OCI Functions | Free (2M/mo) | Start VM via API |
| Idle Monitor | Cron on VM | Free | Stop after timeout |

### Configuration

| Parameter | Value |
|-----------|-------|
| **Idle Timeout** | 15-30 minutes |
| **Wake Time** | 45-60 seconds |
| **Health Check Interval** | 30 seconds |
| **Grace Period After Wake** | 2 minutes |

---

## Cost Summary

### Monthly Costs

| Component | Cost |
|-----------|------|
| GCloud Arch 1 (Free Tier) | $0 |
| Oracle Web 1 (Always Free) | $0 |
| Oracle Services 1 (Always Free) | $0 |
| Oracle E4.Flex 8GB (~150h) | ~$5.50 |
| Block Storage 100GB | ~$2.50 |
| OCI Functions | $0 (Free Tier) |
| **Total** | **~$8/month** |

### Cost Comparison

| Scenario | Monthly Cost |
|----------|--------------|
| All services always-on (no free tier) | ~$80-100 |
| All services always-on (with free tier) | ~$30 |
| **This architecture (dormant)** | **~$8** |
| Savings vs always-on | **73-92%** |

---

## Security Considerations

### Network Security

- All traffic through single NPM (centralized SSL/TLS)
- Let's Encrypt certificates auto-renewed
- Firewall rules per VM (only required ports)
- VPN for administrative access

### Wake System Security

- OCI Function requires IAM authentication
- Wake endpoint protected by API key
- Rate limiting on wake requests
- Audit logging for all wake events

---

## Disaster Recovery

### Backup Strategy

| Data | Frequency | Location |
|------|-----------|----------|
| Matomo DB | Daily | Syncthing → Local |
| Mail | Daily | Syncthing → Local |
| Gitea Repos | Real-time | Syncthing → Local |
| NPM Config | Weekly | Git repo |

### Failover

| Scenario | Action |
|----------|--------|
| GCloud NPM down | DNS failover to Oracle backup |
| Oracle VM down | Manual intervention |
| Paid VM won't wake | Manual start via OCI Console |

---

## Future Considerations

### Oracle ARM Server (24GB - Pending Approval)

When approved, can host:
- n8n AI (1-48GB RAM)
- Heavy AI workloads
- Move Gitea here for more resources

### Scaling Options

| Trigger | Action |
|---------|--------|
| Need more 24/7 services | Add Oracle ARM (free tier) |
| Need more dev resources | Increase E4.Flex RAM |
| Need redundancy | Add second GCloud region |

---

## Document History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-12-02 | Diego | Initial architecture |
| 2.0 | 2025-12-04 | Diego + Claude | Optimized with dormant VM, single NPM |
