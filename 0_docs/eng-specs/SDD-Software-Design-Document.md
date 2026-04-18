# SDD — Software Design Document (IEEE 1016)

> Cloud Infrastructure as Code — Diego Nepomuceno Marcos

---

## 1. Introduction

### 1.1 Purpose
This document describes the software design of the Cloud IaC platform: a self-hosted, fully declarative infrastructure spanning 5 VMs, 59 containerized services, and a WireGuard mesh network.

### 1.2 Scope
Covers all subsystems: build engine, service deployment pipeline, home-manager VM provisioning, cloud-data generation, MCP server ecosystem, and CI/CD automation.

### 1.3 Definitions & Acronyms

| Term | Definition |
|------|-----------|
| IaC | Infrastructure as Code |
| HM | Nix Home Manager |
| WG | WireGuard VPN |
| MCP | Model Context Protocol |
| GHCR | GitHub Container Registry |
| CGC | Code Graph Context |
| DTK | DevOps Toolkit |
| SOPS | Secrets OPerationS (Mozilla) |

### 1.4 References
- `README.md` — User-facing overview
- `0_docs/eng-specs/Cloud-spec.md` — Full cloud specification
- `0_docs/eng-specs/cloud_architecture.json` — Machine-readable architecture
- `I_cloud-data/manifest.json` — Generated data index

---

## 2. System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        DEVELOPER / CLAUDE                       │
│   edit src/ → build.sh ship → GHA auto-deploy on push to main  │
└────────────────────────┬────────────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────────────┐
│                     BUILD ENGINE (_engine.sh)                    │
│   nix build → sops decrypt → rsync → docker compose up         │
└────────────────────────┬────────────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────────────┐
│                     CLOUD INFRASTRUCTURE                        │
│                                                                 │
│  ┌──────────┐  WG   ┌──────────┐  WG   ┌──────────────────┐   │
│  │gcp-proxy │◄─────►│oci-mail  │  │    │oci-apps (ARM)    │   │
│  │ Caddy    │  │    │ Maddy    │  │    │ 35 containers    │   │
│  │ Authelia │  │    │ SMTP     │  │    │ C3 API/MCP       │   │
│  │ DNS      │  │    │ Webmail  │  │    │ Apps + AI        │   │
│  └──────────┘  │    └──────────┘  │    └──────────────────┘   │
│       ▲        │                   │           ▲               │
│       │        │    ┌──────────┐   │           │               │
│       │        └───►│oci-analy │◄──┘    ┌──────────┐          │
│       │             │ Matomo   │        │ gcp-t4   │          │
│       │             │ Dagu     │        │ Ollama   │          │
│  Cloudflare         └──────────┘        └──────────┘          │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3. Design Principles

| # | Principle | Implementation |
|---|-----------|---------------|
| 1 | **Fully Declarative** | All config in Nix flakes + build.json. No imperative VM edits. |
| 2 | **Single Build Interface** | `build.sh` is the ONLY entry point. Never raw nix/docker/npm. |
| 3 | **Data-Driven** | cloud-data JSONs drive Caddy routes, firewall rules, HM configs, GHA workflows. |
| 4 | **Zero Trust Networking** | All inter-VM traffic over WireGuard. Authelia 2FA on every public endpoint. |
| 5 | **Immutable Deployments** | `nix build` produces deterministic outputs. GHCR images are versioned. |
| 6 | **Source of Truth** | `build.json` per service defines everything: name, domain, host, ports, docker, secrets. |

---

## 4. Architectural Design

### 4.1 Component Decomposition

| Component | Location | Responsibility |
|-----------|----------|---------------|
| **Build Engine** | `a_solutions/_engine.sh` | Universal build/deploy pipeline for all 59 services |
| **Service Flakes** | `a_solutions/*/src/flake.nix` | Per-service Nix derivation → docker-compose.yml + configs |
| **Cloud-Data Engine** | `I_cloud-data/engines/` | Derives 26 JSON config files from build.json + config.json |
| **Home Manager** | `b_infra/home-manager/` | VM-level provisioning: packages, cgroups, security, containers |
| **HM Shared Modules** | `b_infra/home-manager/_shared/modules/` | 40+ reusable modules (system-protection, container-control, etc.) |
| **CI/CD** | `.github/workflows/` | Auto-deploy on push, health checks, submodule sync |
| **MCP Servers** | `bc-obs_c3-infra-mcp/`, `bc-obs_cloud-cgc-mcp/`, etc. | Machine-readable infrastructure API for Claude agents |
| **DTK** | `II_tools/` | Operational shell scripts and dashboards |
| **Terraform** | `c_vps/ba-clo_cloudflare/` | Cloudflare DNS zone management |

### 4.2 Data Flow

```
build.json (per service)
    │
    ├──► _engine.sh ──► nix build ──► dist/ ──► rsync ──► VM ──► docker compose
    │
    ├──► cloud-data engines ──► 26 JSON files ──► consumed by:
    │       ├── Caddy (routes)
    │       ├── Authelia (ACLs, OIDC clients)
    │       ├── Home Manager (packages, firewall, containers)
    │       ├── GHA workflows (deploy targets)
    │       ├── Monitoring (targets, alerts)
    │       └── MCP servers (topology, specs)
    │
    └──► config.json (master topology)
```

### 4.3 Security Architecture

```
Layer 0: Network Edge     Cloudflare WAF + DDoS + proxy
Layer 1: Transport        Caddy L4/L7, TLS 1.3, Let's Encrypt
Layer 2: Authentication   Authelia 2FA (TOTP/WebAuthn), OIDC bearer tokens
Layer 3: Network          WireGuard mesh, per-VM firewalls, Docker network isolation
Layer 4: Host             3-tier cgroup slices, FIFO scheduler, watchdog, OOM guards
Layer 5: Application      Container isolation, sops-encrypted secrets, least-privilege
Layer 6: Monitoring       Sauron SIEM (central + lite + forwarder), Fluent Bit, LGTM
```

---

## 5. Module Design

### 5.1 Build Engine (`_engine.sh`)

**Interface**: `build.sh <command>` where build.sh is a symlink to `_engine.sh`.

| Command | Pipeline |
|---------|----------|
| `build` | `nix build ./src` → copy `result/` → `dist/` |
| `secrets` | `sops -d src/secrets.yaml` → `dist/.secrets` |
| `deploy` | `rsync dist/` → `ssh $host:$remote_path` |
| `compose` | `ssh $host "cd $remote_path && docker compose up -d"` |
| `ship` | `build` + `secrets` + `deploy` + `compose` |
| `clean` | Remove `dist/`, `.result` |

**Config source**: Reads `build.json` for host, remote_path, docker registry, secrets options.

### 5.2 Home Manager Modules

System protection stack (deployed to all 5 VMs):

| Module | Purpose |
|--------|---------|
| `system-protection.nix` | Master module, imports all layers |
| `system-protection-layer2-identity.nix` | 3-tier cgroup slice hierarchy |
| `system-protection-scheduler-fifo-rr-cfs.nix` | FIFO on SSH/WG/Dropbear |
| `system-protection-resource-bouncer.nix` | OOM prevention, resource limits |
| `system-protection-watchdog-petter-dropbear-health-agent.nix` | Hardware watchdog + health |
| `system-protection-guardrails.nix` | Safety guards for docker ops |
| `system-protection-systemd-control.nix` | Docker disabled from systemd, container-init owns lifecycle |
| `container-control-daemon.nix` | Docker lifecycle management |
| `container-control-init.nix` | Container startup sequencing |

### 5.3 Cloud-Data Generation

Engine: `I_cloud-data/1_workflows/src/scripts/cloud-data-config.ts` (master) → `cloud-data-config-consolidated.ts` + `cloud-data-config-derive.ts`

**Input**: All `build.json` files + `config.json`
**Output**: 26 per-concern JSON files + `_cloud-data-consolidated.json`
**Trigger**: `git.yaml` pre-push hook (auto-regeneration)

---

## 6. Interface Design

### 6.1 External Interfaces

| Interface | Protocol | Authentication |
|-----------|----------|---------------|
| Public HTTPS | TLS 1.3 via Caddy | Authelia 2FA (browser) or Bearer token (API) |
| WireGuard | UDP 51820 | Pre-shared keys |
| SSH | TCP 22 | Ed25519 keys |
| GHCR | HTTPS | GitHub PAT |
| MCP (HTTP) | HTTPS + SSE | Bearer token |
| MCP (stdio) | stdin/stdout | Local process |

### 6.2 Internal Interfaces

| Interface | Protocol | Purpose |
|-----------|----------|---------|
| Docker networks | Bridge | Container-to-container on same VM |
| WireGuard mesh | UDP | Cross-VM container communication |
| Hickory DNS | DNS over WG | Service discovery (*.app zones) |
| Sauron syslog | TCP/UDP 514 | Centralized log collection |
| ntfy | HTTP | Push notifications between services |

---

## 7. Deployment Design

### 7.1 Environments

| Environment | Purpose | Trigger |
|-------------|---------|---------|
| Local (`build`) | Build + validate only | Manual |
| Production (`ship`) | Full deploy to VM | Manual or GHA on push to main |
| Fallback | Alternative topology | `CLOUD_PROFILE=<name> build.sh profile-ship` |

### 7.2 Image Strategy

- **Nix-built configs**: `nix build` → deterministic docker-compose.yml + config files
- **GHCR images**: Custom Docker images pushed to `ghcr.io/diegonmarcos/*`
- **Remote build**: ARM services use `REMOTE_BUILD=true` (builds on oci-apps)
- **HM delivery**: Home Manager as Docker images via GHCR, VMs pull + activate
