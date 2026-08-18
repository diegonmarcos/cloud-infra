# gcp-f-micro_1

## Overview
| Property | Value |
|----------|-------|
| **ID** | gcp-f-micro_1 |
| **Name** | GCP Free Micro 1 |
| **Provider** | Google Cloud |
| **Instance Type** | e2-micro |
| **Hostname** | arch-1 |
| **Status** | PRODUCTION |

## Specs
| Resource | Value |
|----------|-------|
| **CPU** | 0.25-2 vCPU |
| **RAM** | 1 GB |
| **Storage** | 30 GB |

## Network
| Property | Value |
|----------|-------|
| **Public IP** | 35.226.147.64 |
| **WireGuard IP** | 10.0.0.1 (hub) |
| **Region** | us-central1 |
| **Zone** | us-central1-a |

## OS
| Property | Value |
|----------|-------|
| **Name** | Fedora (Arch-based custom) |
| **Kernel** | 6.17.8-200.fc42.x86_64 |
| **Arch** | x86_64 |

## SSH Access
```bash
ssh -F ~/git/cloud-vault/config_mobile gcp-proxy
# or: gcloud compute ssh arch-1 --zone us-central1-a
```

## Services Running
| Service | Container | Port | Network |
|---------|-----------|------|---------|
| NPM (reverse proxy) | npm | 80, 443, 81 | npm_default |
| Authelia (SSO) | authelia | 127.0.0.1:9091 | auth-net |
| Authelia Redis | authelia-redis | 127.0.0.1:6379 | auth-net |
| Vaultwarden | vaultwarden | - | npm_default |
| ntfy (push notif) | ntfy | 127.0.0.1:8090 | npm_default |
| github-rss | github-rss | - | npm_default |
| syslog-bridge | syslog-bridge | - | npm_default |
| Flask API | flask-api | 5000 | npm_default |
| C3 Collector | c3-collector | - | npm_default |
| Sauron (security) | sauron | - | npm_default |
| Sauron Forwarder | sauron-forwarder | - | npm_default |
| Event Collector | collector | - | npm_default |
| Palantir Monitor | palantir-monitor | - | monitor |
| Palantir Cron | palantir-cron | - | monitor |
| Postlite (SQLite REST) | sqlite-* / postlite-* | 10.0.0.1:8880-8883 | postlite_default |

## Docker Networks
- npm_default (main shared network)
- auth-net / authelia_auth-net
- palantir-monitor_monitor
- sauron-lite_security / sauron_security / sauron-central_security
- postlite_default / postlite_sqlite_net
- ntfy_default, fluent-bit_default

## OS Config Files
- `/etc/wireguard/wg0.conf` - WireGuard hub (see wireguard-wg0.conf)
- Systemd timer: `authelia-backup.timer` - Daily 03:00 UTC SQLite backup
- Backup script: `/home/diego/backups/authelia/backup.sh`

## Budget Protection
- Billing disabler Cloud Function enabled
- Budget alerts configured

## Notes
- WireGuard hub connecting all 4 VMs + mobile
- Main reverse proxy for all *.diegonmarcos.com
- Authelia SSO with auth-request + forward-auth endpoints
