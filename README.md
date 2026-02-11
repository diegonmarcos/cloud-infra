# Cloud Infrastructure

Self-hosted cloud services across Oracle Cloud and Google Cloud free tiers, with Cloudflare edge and WireGuard mesh networking.

---

## Virtual Machines

### Always-On (24/7) — Free Tier

| VM | Alias | IP | WG IP | RAM | Services |
|----|-------|----|-------|-----|----------|
| gcp-f-micro_1 | gcp-proxy | 35.226.147.64 | 10.0.0.1 | 1 GB | Caddy, Authelia, Vaultwarden, ntfy, API |
| oci-f-micro_1 | oci-mail | 130.110.251.193 | 10.0.0.3 | 1 GB | Mailu, Syncthing, Radicale |
| oci-f-micro_2 | oci-analytics | 129.151.228.66 | 10.0.0.4 | 1 GB | Matomo, Windmill (hybrid toggle) |

### Wake-on-Demand — Paid

| VM | Alias | IP | WG IP | RAM | Services |
|----|-------|----|-------|-----|----------|
| oci-p-flex_1 | oci-flex | 144.24.196.72 | 10.0.0.2 | 8 GB | PhotoPrism, NocoDB, Code Server, AFFiNE |

---

## Networking

All VMs connected via **WireGuard mesh** (hub: gcp-proxy `10.0.0.1`).

**Traffic flow**: `Cloudflare → Caddy (gcp-proxy) → WireGuard → target VM`

**Authentication**:
- **Browser**: Authelia forward-auth (cookie/session + 2FA via TOTP/WebAuthn)
- **CLI/API**: Bearer token via introspect-proxy (OIDC token introspection)

SSH aliases: `ssh oci-flex`, `ssh oci-mail`, `ssh oci-analytics`, `ssh gcp-proxy`.

---

## Active Services

| Service | Domain | VM | Port | Availability |
|---------|--------|----|------|--------------|
| Caddy Proxy | proxy.diegonmarcos.com | gcp-proxy | 80/443 | 24/7 |
| Authelia 2FA | auth.diegonmarcos.com | gcp-proxy | 9091 | 24/7 |
| Vaultwarden | vault.diegonmarcos.com | gcp-proxy | 80 | 24/7 |
| ntfy Push | rss.diegonmarcos.com | gcp-proxy | 8090 | 24/7 |
| API (Flask+Rust) | api.diegonmarcos.com | gcp-proxy | 5000/8080 | 24/7 |
| Mailu Mail | mail.diegonmarcos.com | oci-mail | 8444 | 24/7 |
| Syncthing | sync.diegonmarcos.com | oci-mail | 8384 | 24/7 |
| Radicale Calendar | cal.diegonmarcos.com | oci-mail | 5232 | 24/7 |
| Matomo Analytics | analytics.diegonmarcos.com | oci-analytics | 8080 | 24/7 (hybrid) |
| Windmill | — | oci-analytics | — | 24/7 (toggles with Matomo) |
| PhotoPrism | photos.diegonmarcos.com | oci-flex | 3013 | wake-on-demand |
| NocoDB | db.diegonmarcos.com | oci-flex | 8085 | wake-on-demand |
| Code Server | ide.diegonmarcos.com | oci-flex | 8443 | wake-on-demand |
| AFFiNE | drive-notes-affine.diegonmarcos.com | oci-flex | 3010 | wake-on-demand |

---

## Repository Structure

```
cloud/
├── 0.spec/                        # Specifications & planning (v1, v2, v3)
├── 1.ops/                         # Operations scripts (archive)
│
├── a_solutions/
│   ├── home-manager/              # Nix Home Manager for all 4 VMs
│   │   ├── flake.nix              # Main flake (gcp-proxy, oci-flex, oci-mail, oci-analytics)
│   │   ├── wireguard.nix          # WireGuard mesh config
│   │   ├── deploy.sh              # Automated deployment
│   │   └── build.sh + build.json  # Standard build system
│   │
│   ├── container-nix/             # 43 containerized services (Nix flakes)
│   │   ├── aa-sui_*               # Suite apps (AFFiNE, Code Server, Mailu, PhotoPrism...)
│   │   ├── ab-mic_*               # Misc (Syncthing, Vaultwarden)
│   │   ├── ba-clo_*               # Cloud providers (Cloudflare Terraform, gcloud, oci)
│   │   ├── bb-sec_*               # Security (Authelia, Caddy, APIs)
│   │   ├── bc-obs_*               # Observability (Matomo, NocoDB, ntfy, LGTM, Windmill)
│   │   └── ca-dat_*               # Data & backups (Borg, Gitea, Redis)
│   │
│   └── z_backup_all/              # Backup archives & encryption
│
├── b_infra/                       # VM infrastructure configs
│   ├── vm_gcp-f-micro_1/          # GCP proxy VM (iptables, sshd, wireguard, systemd)
│   ├── vm_oci-f-micro_1/          # OCI mail VM
│   ├── vm_oci-f-micro_2/          # OCI analytics VM
│   ├── vm_oci-p-flex_1/           # OCI flex VM (idle shutdown management)
│   ├── vps_gcloud/                # GCP VPS configs
│   └── vps_oracle/                # OCI VPS configs
│
├── c_myhardware/                  # Local hardware configs (Surface Pro 8)
└── .github/workflows/             # CI/CD (Rust API build)
```

---

## Container-Nix Projects (43 services)

Each service is a standalone Nix flake with `build.sh` + `build.json` at project root, producing Docker Compose configurations.

**Naming convention**: `<priority><category>_<service>`

| Prefix | Category | Examples |
|--------|----------|----------|
| `aa-sui_` | Suite apps | AFFiNE, Code Server, Mailu, PhotoPrism, Radicale |
| `ab-mic_` | Misc | Syncthing, Vaultwarden |
| `ba-clo_` | Cloud providers | Cloudflare (Terraform), gcloud, oci |
| `bb-sec_` | Security | Authelia, Caddy, Flask API, Rust API, MCP Server |
| `bc-obs_` | Observability | Matomo, NocoDB, ntfy, LGTM, Windmill, Dozzle |
| `ca-dat_` | Data & backups | Borg, Gitea, Redis, PostLite |

---

## Home Manager

All 4 VMs use Nix Home Manager for reproducible user environments (`a_solutions/home-manager/`).

```bash
# Deploy to a specific VM
~/git/cloud/a_solutions/home-manager/deploy.sh gcp-proxy
~/git/cloud/a_solutions/home-manager/deploy.sh oci-flex
```

Standard tools deployed to all VMs: sops, age, jq, yq, rsync, rclone, curl, wget, htop, btop, ncdu, ripgrep, fd, bat, git, gh.

---

## Cloud Providers

| Provider | Tier | Region | Purpose |
|----------|------|--------|---------|
| Oracle Cloud | Always Free | eu-marseille-1 | 3 VMs (mail, analytics, flex) |
| Google Cloud | Free Tier | us-central1 | 1 VM (proxy/gateway) |
| Cloudflare | Free | Global | DNS, proxy, DDoS protection |
| GitHub Pages | Free | Global | Static site hosting |

---

## Key Operations

```bash
# Matomo hybrid toggle (oci-analytics shares 1GB RAM)
~/git/cloud/a_solutions/container-nix/bc-obs_matomo/build.sh wake   # stops windmill, wakes matomo
~/git/cloud/a_solutions/container-nix/bc-obs_matomo/build.sh sleep  # sleeps matomo, starts windmill

# Deploy container service
~/git/cloud/a_solutions/container-nix/<service>/build.sh

# Cloudflare DNS (Terraform)
~/git/cloud/a_solutions/container-nix/ba-clo_cloudflare/build.sh
```

---

**Last Updated**: 2026-02-11
