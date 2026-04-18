# BRD — Business Requirements Document

> Cloud Infrastructure as Code — Diego Nepomuceno Marcos

---

## 1. Executive Summary

Build and maintain a fully self-hosted cloud platform that replaces commercial SaaS services (Google Workspace, iCloud, Notion, Bitwarden, etc.) with open-source alternatives running on free-tier cloud infrastructure. Total operating cost: $0/month.

---

## 2. Business Objectives

| # | Objective | Measurable Outcome |
|---|-----------|-------------------|
| 1 | **Digital Sovereignty** | 100% of personal data on owned infrastructure |
| 2 | **Zero Vendor Lock-in** | All services have open-source replacements |
| 3 | **Zero Recurring Cost** | $0/month cloud spend (free-tier only) |
| 4 | **Single-Operator Scale** | 59 services managed by 1 person via automation |
| 5 | **Professional Portfolio** | Demonstrates full-stack DevOps/SRE capability |

---

## 3. Scope

### 3.1 In Scope
- Self-hosted replacements for: email, file storage, photos, documents, spreadsheets, calendar, contacts, passwords, chat, analytics, IDE, git hosting, workflow automation, web scraping, AI/LLM inference
- Infrastructure management: automated deployment, monitoring, backups, security
- AI-assisted operations: MCP servers for Claude agent infrastructure management

### 3.2 Out of Scope
- Multi-user SaaS (single-tenant only)
- Commercial customer-facing services
- Paid cloud resources (except on-demand GPU spot instances)

---

## 4. Commercial Services Replaced

| Commercial Service | Self-Hosted Replacement | Annual Savings |
|-------------------|------------------------|----------------|
| Google Workspace (Gmail, Drive, Docs, Sheets) | Maddy, FileBrowser, HedgeDoc, Grist | ~$72/yr |
| iCloud (Photos) | PhotoPrism | ~$36/yr |
| Notion/Confluence | HedgeDoc, Etherpad | ~$96/yr |
| Bitwarden Premium | Vaultwarden | ~$10/yr |
| Slack/Teams | Mattermost | ~$84/yr |
| Google Analytics | Matomo, Umami | ~$108/yr |
| GitHub Codespaces | Code Server | ~$48/yr |
| Grafana Cloud | LGTM (self-hosted) | ~$120/yr |
| n8n/Zapier | Dagu | ~$240/yr |
| Apify (scraping) | Crawlee Cloud | ~$49/yr |
| OpenAI API | Ollama (local LLMs) | Variable |
| CalDAV/CardDAV | Radicale | ~$36/yr |
| **Total estimated savings** | | **~$900+/yr** |

---

## 5. Success Criteria

| Criteria | Target | Current |
|----------|--------|---------|
| Services deployed | 50+ | 59 |
| Monthly cost | $0 | $0 |
| Uptime (P0 services) | 99%+ | ~99% |
| Deploy automation | 100% | 100% (build.sh + GHA) |
| Secret management | 100% encrypted | 100% (SOPS + age) |
| MCP coverage | All services queryable | 7 MCP servers, 150+ tools |

---

## 6. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| Free-tier service changes | Medium | High | Portable Nix flakes, can migrate to any provider |
| Single point of failure (operator) | High | High | Full IaC, MCP automation, comprehensive docs |
| VM resource exhaustion | Medium | Medium | System protection (cgroups, watchdog), Matomo hybrid |
| Data loss | Low | Critical | Daily backups (Borg + bup → OCI Object Storage) |
| Security breach | Low | Critical | 6-layer security, 2FA, encrypted secrets, Sauron SIEM |

---

## 7. Stakeholder Sign-Off

| Role | Name | Status |
|------|------|--------|
| Owner / Developer / Operator | Diego Nepomuceno Marcos | Approved |
