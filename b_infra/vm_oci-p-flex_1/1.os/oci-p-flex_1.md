# oci-p-flex_1

## Overview
| Property | Value |
|----------|-------|
| **ID** | oci-p-flex_1 |
| **Name** | OCI Paid Flex 1 |
| **Provider** | Oracle Cloud |
| **Instance Type** | VM.Standard.A1.Flex (4 OCPU, 24GB) |
| **Hostname** | oci-p-flex-1 |
| **OCID** | ocid1.instance.oc1.eu-marseille-1.anwxeljruadvczach3pczd4kn6w5stdt7rs64u2uqexzor6lyneaebc2i2ra |
| **Status** | PRODUCTION |

## Specs
| Resource | Value |
|----------|-------|
| **CPU** | 4 OCPU (Ampere A1 ARM) |
| **RAM** | 24 GB |
| **Storage** | 200 GB |
| **Arch** | aarch64 (ARM64) |

## Network
| Property | Value |
|----------|-------|
| **Public IP** | 144.24.196.72 |
| **WireGuard IP** | 10.0.0.2 |
| **Region** | eu-marseille-1 |
| **Docker Network** | dev_network (172.24.0.0/24) |

## OS
| Property | Value |
|----------|-------|
| **Name** | Ubuntu 24.04 LTS |
| **Kernel** | 6.14.0-1018-oracle |
| **Arch** | aarch64 |

## SSH Access
```bash
# From GCP hub:
ssh -i ~/.ssh/id_rsa ubuntu@144.24.196.72
# Or via WireGuard:
ssh -i ~/.ssh/id_rsa ubuntu@10.0.0.2
```

## Services Running
| Service | Container | Port | Network |
|---------|-----------|------|---------|
| NocoDB (main) | nocodb | 8085 | dev_network + nocodb_network |
| NocoDB Postgres | nocodb-db | - | nocodb_network |
| NocoDB (front-suite) | nocodb_app | 3020 | dev_network |
| NocoDB Postgres (front-suite) | nocodb_postgres | - | dev_network |
| PhotoPrism (main) | photoprism | 10.0.0.2:2342 | dev_network |
| PhotoPrism MariaDB | photoprism-db | 127.0.0.1:3307 | dev_network |
| PhotoPrism (front-suite) | photoprism_app | 3013 | dev_network |
| PhotoPrism MariaDB (front-suite) | photoprism_mariadb | - | dev_network |
| Radicale (calendar) | radicale | 10.0.0.2:5232 | dev_network |
| Redis | redis | 6379 | dev_network |
| HedgeDoc (notes) | hedgedoc_app | 3010 | dev_network |
| HedgeDoc Postgres | hedgedoc_postgres | - | dev_network |
| Etherpad (docs) | etherpad_app | 3012 | dev_network |
| Etherpad Postgres | etherpad_postgres | - | dev_network |
| Filebrowser | filebrowser_app | 3015 | dev_network |
| Grist (sheets) | grist_app | 3011 | dev_network |
| RevealMD (slides) | revealmd_app | 3014 | dev_network |
| Grafana | lgtm_grafana | 3016 | dev_network |
| Loki | lgtm_loki | 3017 | dev_network |
| Tempo | lgtm_tempo | 3018 | dev_network |
| Mimir | lgtm_mimir | 3019 | dev_network |
| Gitea | gitea | 3000, 2222 | gitea_backup_network |
| Sauron (security) | sauron | - | sauron_security |
| Collector | collector | - | host |
| Fluent-bit | fluent-bit | - | - |

## Docker Networks
- dev_network (main shared network)
- nocodb_network (172.25.0.0/24)
- gitea_backup_network
- sauron_security

## OS Config Files
- `/etc/wireguard/wg0.conf` - WireGuard spoke (see wireguard-wg0.conf)
- iptables: SSH + ICMP + WireGuard (10.0.0.0/24) ACCEPT, REJECT default

## Wake-on-Demand Architecture
This VM is **wake-on-demand** to save costs:
- Heavy services run here instead of free-tier VMs
- Auto-shutdown via idle detection timer

### Auto-Shutdown (Idle Detection)
**Script:** `/opt/scripts/idle-shutdown.sh`
**Timer:** `idle-shutdown.timer` (runs every 5 minutes)
**Timeout:** 30 minutes (1800 seconds) of inactivity

## Notes
- ARM64 (aarch64) - all images must support arm64
- All containers set to `restart: unless-stopped` (fixed 2026-02-07)
- Main suite hosting: docs, sheets, slides, photos, calendar, notes, DB
