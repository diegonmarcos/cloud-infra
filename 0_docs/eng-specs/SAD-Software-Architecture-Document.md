# SAD — Software Architecture Document (ISO/IEC/IEEE 42010 + arc42)

> Cloud Infrastructure as Code — Diego Nepomuceno Marcos

---

## 1. Introduction & Goals

### 1.1 Requirements Overview
A fully declarative, self-hosted cloud platform running on free-tier VMs (Oracle Cloud + Google Cloud) with:
- 59 containerized services across 5 VMs
- Zero manual configuration — everything ships via `build.sh`
- WireGuard mesh for all inter-VM traffic
- 2FA on every public endpoint
- Data-driven configuration generation from build.json

### 1.2 Quality Goals

| Priority | Goal | Measure |
|----------|------|---------|
| 1 | **Declarative** | 0 imperative VM edits. All state in git. |
| 2 | **Secure** | 6-layer security. No plaintext secrets in git. |
| 3 | **Reproducible** | Nix flakes ensure deterministic builds. |
| 4 | **Observable** | Every service reachable via MCP tools. |
| 5 | **Cost-efficient** | Runs entirely on free-tier cloud resources. |

### 1.3 Stakeholders

| Role | Concern |
|------|---------|
| Owner/Developer | Single operator. Full access. |
| Claude Agents | MCP-driven infrastructure management. |
| External Users | Public-facing services (mail, photos, docs). |

---

## 2. Constraints

| Constraint | Impact |
|------------|--------|
| Free-tier VMs (1GB RAM on 3 of 5 VMs) | Matomo hybrid sleep/wake, careful resource allocation |
| Single ARM VM (oci-apps, aarch64) | `REMOTE_BUILD=true` for Docker images, no cross-compilation |
| Cloudflare proxy required | All traffic through CF, no direct IP access |
| Nix flakes only | No system-level flakes, everything in-repo |
| SOPS + age encryption | All secrets in `src/secrets.yaml`, never plaintext |

---

## 3. Context & Scope

### 3.1 Business Context

```
┌─────────────┐     HTTPS      ┌──────────────┐
│  Browser /   │───────────────►│  Cloudflare   │
│  CLI / API   │                │  (DNS+Proxy)  │
└─────────────┘                └───────┬───────┘
                                       │
┌─────────────┐     MCP        ┌───────▼───────┐
│  Claude      │───────────────►│  Cloud        │
│  Agents      │  stdio/HTTP    │  Platform     │
└─────────────┘                └───────────────┘
                                       │
┌─────────────┐     SSH/rsync  ┌───────▼───────┐
│  Developer   │───────────────►│  build.sh     │
│  (Diego)     │  git push      │  GHA CI/CD    │
└─────────────┘                └───────────────┘
```

### 3.2 Technical Context

```
                    ┌───────────────────────────────────────┐
                    │           CLOUD PLATFORM              │
                    │                                       │
  Cloudflare ──────►│  gcp-proxy (x86, 1GB)                │
  (443/TCP)        │  ├── Caddy (reverse proxy)            │
                    │  ├── Authelia (2FA)                   │
                    │  ├── Hickory DNS                      │
                    │  ├── Redis                            │
                    │  └── Introspect Proxy                 │
                    │           │ WireGuard                  │
                    │  ┌───────┼───────┬───────────┐       │
                    │  ▼       ▼       ▼           ▼       │
                    │  oci-    oci-    oci-apps    gcp-t4  │
                    │  mail    analy   (ARM,16GB)  (GPU)   │
                    │  (1GB)   (1GB)   35 svcs     Ollama  │
                    │  Mail    Matomo  Apps+API             │
                    │  SMTP    Dagu    MCP+AI              │
                    └───────────────────────────────────────┘
```

---

## 4. Solution Strategy

| Decision | Rationale |
|----------|-----------|
| **Nix flakes for everything** | Reproducible builds, declarative config, no drift |
| **build.json as source of truth** | Single file defines service identity, domain, host, ports, docker, secrets |
| **cloud-data generation** | 26 JSON files derived from build.json — consumed by Caddy, Authelia, HM, GHA |
| **WireGuard hub-and-spoke** | Encrypted inter-VM traffic, simple topology, gcp-proxy as hub |
| **Home Manager via Docker/GHCR** | Avoid rebuilding nix closures on VMs, pull pre-built images |
| **MCP servers** | Machine-readable infrastructure for Claude agents, 70+ tools |
| **Unified ship.yml** | One GHA workflow auto-detects target VM from build.json |

---

## 5. Building Block View

### Level 1: Top-Level Decomposition

```
cloud/
├── a_solutions/     ← 59 services (the "what")
├── b_infra/         ← VM provisioning (the "where")
├── c_vps/           ← Cloud provider configs (the "how to provision")
├── I_cloud-data/    ← Generated config hub (the "derived truth")
├── II_tools/        ← Operational toolkit (the "how to operate")
├── 0_docs/          ← Documentation (the "why")
├── 1_workflows/     ← CI/CD engine (the "how to ship")
└── .github/         ← GHA workflow definitions
```

### Level 2: Service Categories (a_solutions/)

| Category | Prefix | Count | Examples |
|----------|--------|-------|---------|
| Applications | `aa-sui_` | 15 | code-server, mattermost, photoprism, grist, hedgedoc |
| Microservices | `ab-mic_` | 1 | vaultwarden |
| Financial | `ac-fin_` | 3 | crawlee-cloud, quant-lab-full, quant-lab-light |
| AI/AGI | `ad-agi_` | 4 | ollama, ollama-arm, ollama-hai, rig-agentic (x2) |
| Cloud | `ba-clo_` | 3 | cloudflare-worker, gcloud, hickory-dns |
| Security | `bb-sec_` | 6 | authelia, caddy, caddy-l4-image, introspect-proxy, orchestrator, sauron-central |
| Observability | `bc-obs_` | 18 | c3-infra-api/mcp, cloud-cgc-mcp, matomo, dagu, lgtm |
| Data | `ca-dat_` | 8 | gitea, kg-graph, redis, backup-borg/bup, db-agent |

### Level 3: Single Service Internals

```
<service>/
├── build.sh → ../_engine.sh
├── build.json              ← Identity + config
└── src/
    ├── flake.nix           ← Nix derivation
    │   └── outputs:
    │       ├── docker-compose.yml
    │       ├── Dockerfile (optional)
    │       └── config files
    ├── secrets.yaml         ← SOPS-encrypted
    └── *.nix / *.ts / ...  ← Service-specific source
```

---

## 6. Runtime View

### 6.1 Deploy Sequence (build.sh ship)

```
Developer                Engine              VM
    │                      │                  │
    │── build.sh ship ────►│                  │
    │                      │── nix build ────►│(local)
    │                      │◄── dist/ ────────│
    │                      │── sops decrypt ──│
    │                      │── rsync dist/ ──►│
    │                      │── ssh compose ──►│
    │                      │                  │── docker compose up
    │◄── done ─────────────│                  │
```

### 6.2 Request Flow (HTTPS)

```
Client → Cloudflare → gcp-proxy:443
    → Caddy (TLS termination, route matching)
        → Authelia (forward-auth check)
            → if browser: cookie/session + 2FA
            → if API: Bearer token → introspect-proxy → OIDC validation
        → WireGuard tunnel → target VM:port
            → Docker container
```

### 6.3 Cloud-Data Regeneration

```
git push → pre-push hook (git.yaml)
    → cloud-data-config-consolidated.ts reads all build.json + config.json → _cloud-data-consolidated.json
    → cloud-data-config-derive.ts produces per-consumer JSON files
    (orchestrated by cloud-data-config.ts in cloud-data/1_workflows/src/scripts/)
    → committed to I_cloud-data/
    → GHA ship-gen-configs.yml detects changes → deploys consumers
```

---

## 7. Deployment View

```
                    ┌─────────────────────────┐
                    │      GitHub (GHCR)       │
                    │  Docker images           │
                    │  HM images               │
                    └────────┬────────────────┘
                             │ docker pull
         ┌───────────────────┼───────────────────┐
         ▼                   ▼                   ▼
  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
  │  gcp-proxy   │  │  oci-mail    │  │  oci-apps    │
  │  x86 / 1GB   │  │  x86 / 1GB  │  │  ARM / 16GB  │
  │  5 services  │  │  4 services  │  │  35 services │
  └──────────────┘  └──────────────┘  └──────────────┘
         ▲                               ▲
         │              ┌────────────────┘
  ┌──────────────┐  ┌──────────────┐
  │oci-analytics │  │   gcp-t4     │
  │  x86 / 1GB   │  │  x86 / 16GB  │
  │  6 services  │  │  1 service   │
  └──────────────┘  └──────────────┘
```

---

## 8. Crosscutting Concepts

### 8.1 Secrets Management
All secrets in `src/secrets.yaml` (SOPS + age). Engine decrypts to `dist/.secrets` (KEY=VALUE env file). `escape_dollars: true` for hashes containing `$`.

### 8.2 Observability
- **Logs**: Fluent Bit → Sauron Central, Dozzle for real-time
- **Metrics**: LGTM stack (Grafana + Loki + Tempo + Mimir)
- **Health**: C3 API tiered health checks (tier1/2/3)
- **Alerts**: ntfy push notifications

### 8.3 System Protection (all VMs)
- 3-tier cgroup slice hierarchy
- FIFO scheduling on critical services (SSH, WireGuard, Dropbear)
- Hardware watchdog + health agent
- Resource bouncer (OOM prevention)
- Container-init owns Docker lifecycle (systemd disabled)

---

## 9. Architecture Decisions

| ADR | Decision | Context |
|-----|----------|---------|
| 001 | Nix flakes in-repo, not system-level | Reproducibility, portability |
| 002 | build.json as single source of truth | Eliminates config duplication |
| 003 | cloud-data generation (26 JSONs) | Data-driven config for all consumers |
| 004 | WireGuard hub-and-spoke, not full mesh | Simpler key management, single hub |
| 005 | HM delivery via Docker/GHCR | Avoid slow nix-copy over SSH |
| 006 | Unified ship.yml workflow | One workflow replaces 5 per-VM workflows |
| 007 | MCP servers for infrastructure | Claude agents can manage infra programmatically |
| 008 | Matomo hybrid sleep/wake | 1GB RAM constraint on oci-analytics |
| 009 | REMOTE_BUILD for ARM | No cross-compilation, build on target VM |
| 010 | FIFO scheduler on SSH/WG | Bulletproof access even under 100% CPU stress |

---

## 10. Risks & Technical Debt

| Risk | Mitigation |
|------|-----------|
| Single operator (bus factor = 1) | Full IaC, everything in git, MCP for automation |
| Free-tier resource limits | Matomo hybrid, careful container allocation, cgroup slicing |
| ARM cross-compilation | REMOTE_BUILD flag, GHCR pre-built images |
| cloud-data stale after manual edits | Pre-push hook auto-regeneration, drift detection |
| 1GB VM OOM | System protection: watchdog, resource bouncer, FIFO scheduler |
