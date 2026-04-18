# PRD — Product Requirements Document

> Cloud Infrastructure as Code — Diego Nepomuceno Marcos

---

## 1. Product Overview

### 1.1 Vision
A personal, self-hosted cloud platform that provides full digital sovereignty: email, files, photos, documents, analytics, development tools, and AI — all running on free-tier cloud resources with zero vendor lock-in.

### 1.2 Problem Statement
Commercial cloud services (Google Workspace, iCloud, Notion, etc.) create vendor dependency, expose personal data to third parties, and impose recurring costs. A self-hosted alternative must be:
- **Free** to operate (free-tier VMs only)
- **Private** (all data on owned infrastructure)
- **Reliable** (automated recovery, monitoring, redundancy)
- **Maintainable** by a single operator (fully automated via IaC)

### 1.3 Target Users

| User | Needs |
|------|-------|
| **Owner (Diego)** | Full digital workspace: email, files, code, notes, analytics |
| **Claude Agents** | Programmatic infrastructure management via MCP |
| **External contacts** | Email delivery, shared documents, calendar invites |

---

## 2. Product Goals & Success Metrics

| Goal | Metric | Target |
|------|--------|--------|
| **Self-hosted replacement** | Commercial services eliminated | 15+ services replaced |
| **Zero recurring cost** | Monthly cloud spend | $0 (free-tier only, GPU on-demand) |
| **Uptime** | Service availability | 99%+ for critical services |
| **Deploy speed** | Time from git push to live | < 5 minutes |
| **Security** | Public-facing endpoints with 2FA | 100% |
| **Automation** | Manual VM interventions per month | 0 |

---

## 3. User Stories

### 3.1 Communication
| ID | Story | Service |
|----|-------|---------|
| COM-01 | As a user, I can send/receive email at me@diegonmarcos.com | Maddy, SnappyMail |
| COM-02 | As a user, I can access webmail from any browser | SnappyMail |
| COM-03 | As a user, I receive push notifications for system events | ntfy |
| COM-04 | As a user, I can chat with bots and receive alerts | Mattermost |

### 3.2 Productivity
| ID | Story | Service |
|----|-------|---------|
| PRD-01 | As a user, I can edit documents collaboratively | HedgeDoc, Etherpad |
| PRD-02 | As a user, I can manage spreadsheets and databases | Grist |
| PRD-03 | As a user, I can manage my calendar and contacts | Radicale |
| PRD-04 | As a user, I can store and manage files via web UI | FileBrowser |
| PRD-05 | As a user, I can store passwords securely | Vaultwarden |
| PRD-06 | As a user, I can create presentations from markdown | Reveal.md |

### 3.3 Development
| ID | Story | Service |
|----|-------|---------|
| DEV-01 | As a developer, I can code from any browser | Code Server |
| DEV-02 | As a developer, I can host git repos with CI | Gitea |
| DEV-03 | As a developer, I can manage databases via web UI | DBGate |
| DEV-04 | As a developer, I can orchestrate workflows | Dagu |
| DEV-05 | As a developer, I can scrape and extract web data | Crawlee Cloud |
| DEV-06 | As a developer, I can run quantitative analysis | Quant Lab |

### 3.4 Media & Personal
| ID | Story | Service |
|----|-------|---------|
| MED-01 | As a user, I can browse AI-organized photos | PhotoPrism |
| MED-02 | As a user, I can track website analytics (privacy-first) | Matomo, Umami |

### 3.5 AI & Automation
| ID | Story | Service |
|----|-------|---------|
| AI-01 | As a user, I can run local LLMs (14B on GPU, 1.5B on ARM) | Ollama, Rig Agentic |
| AI-02 | As a user, Claude agents can manage my infrastructure | C3 MCP, Cloud CGC MCP |
| AI-03 | As a user, I can query a knowledge graph of my infra | KG Graph, Octocode |
| AI-04 | As a user, Claude can access my Google Workspace | Google Workspace MCP |
| AI-05 | As a user, Claude can read/send mail on my behalf | Mail MCP |

### 3.6 Operations
| ID | Story | Service |
|----|-------|---------|
| OPS-01 | As an operator, I can deploy any service with one command | build.sh ship |
| OPS-02 | As an operator, I can monitor all containers in real-time | Dozzle, LGTM |
| OPS-03 | As an operator, I can view centralized security logs | Sauron Central |
| OPS-04 | As an operator, backups run automatically | Backup Borg/Bup, DB Agent |
| OPS-05 | As an operator, VMs auto-recover from crashes | Watchdog, Container-Init |

---

## 4. Feature Prioritization

### P0 — Critical (must always be running)
- Email (Maddy + SMTP Proxy + SnappyMail)
- Authentication (Authelia + Caddy + Introspect Proxy)
- Networking (WireGuard + Hickory DNS)
- Passwords (Vaultwarden)
- Push notifications (ntfy)

### P1 — Important (daily use)
- Photos (PhotoPrism)
- Documents (HedgeDoc, Grist)
- Calendar/Contacts (Radicale)
- Chat (Mattermost)
- Code (Code Server, Gitea)
- Analytics (Matomo)

### P2 — Useful (regular use)
- MCP servers (C3 Infra, CGC, Services)
- Workflows (Dagu)
- Monitoring (LGTM, Dozzle, Sauron)
- AI (Ollama, Rig Agentic)
- Scraping (Crawlee Cloud)

### P3 — Nice to have
- FileBrowser
- Etherpad
- Reveal.md
- Quant Lab
- Umami

---

## 5. Non-Functional Requirements

| Category | Requirement |
|----------|------------|
| **Cost** | $0/month for always-on services. GPU (gcp-t4) is on-demand spot only. |
| **Security** | 2FA on all public endpoints. Secrets encrypted at rest (SOPS). Zero trust networking. |
| **Privacy** | No third-party analytics. Self-hosted alternatives for all services. |
| **Availability** | Critical services (P0) must survive VM restarts automatically. |
| **Performance** | Services on 1GB VMs must fit within memory constraints (Matomo hybrid). |
| **Maintainability** | Single operator. All config in git. Deploy via `build.sh ship`. |
| **Portability** | Nix flakes + Docker. Can migrate to any Linux VM. |
| **Backup** | Daily automated backups to OCI Object Storage (Borg + bup). |

---

## 6. Constraints & Dependencies

| Constraint | Impact |
|------------|--------|
| Oracle Cloud free tier: 4 VMs (1x ARM 24GB + 2x E2 1GB + 1 E2 1GB) | Service allocation strategy |
| Google Cloud free tier: 1x E2 1GB + T4 GPU spot | Gateway + on-demand AI |
| Cloudflare free tier: DNS + proxy only | No advanced WAF features |
| Single operator | Full automation required, MCP for delegation |
| ARM architecture (oci-apps) | Some Docker images need ARM builds |

---

## 7. Roadmap

See `ROADMAP.md` for detailed implementation timeline.

| Phase | Status | Description |
|-------|--------|-------------|
| Core Infrastructure | Done | 5 VMs, WireGuard, Caddy, Authelia, build engine |
| Application Layer | Done | 59 services deployed |
| Data-Driven Config | Done | 26 cloud-data JSONs, build.json as source of truth |
| MCP Ecosystem | Done | 7 MCP servers, 150+ tools |
| System Protection | Done | 3-tier cgroups, FIFO scheduler, watchdog |
| Observability | In Progress | LGTM stack, Sauron SIEM, Fluent Bit |
| Backup Automation | In Progress | Borg + bup + DB Agent |
