# oci-f-micro_1

## Overview
| Property | Value |
|----------|-------|
| **ID** | oci-f-micro_1 |
| **Name** | OCI Free Micro 1 |
| **Provider** | Oracle Cloud |
| **Instance Type** | VM.Standard.E2.1.Micro |
| **Hostname** | web-server |
| **OCID** | ocid1.instance.oc1.eu-marseille-1.anwxeljruadvczacbwylmkqr253ay7binepapgsyopllfayovkzaky6oigbq |
| **Status** | PRODUCTION |

## Specs
| Resource | Value |
|----------|-------|
| **CPU** | 1 OCPU (AMD) |
| **RAM** | 1 GB |
| **Storage** | 47 GB |
| **Arch** | x86_64 |

## Network
| Property | Value |
|----------|-------|
| **Public IP** | 130.110.251.193 |
| **WireGuard IP** | 10.0.0.3 |
| **Region** | eu-marseille-1 |

## OS
| Property | Value |
|----------|-------|
| **Name** | Ubuntu 24.04 LTS |
| **Kernel** | 6.14.0-1017-oracle |
| **Arch** | x86_64 |

## SSH Access
```bash
# From GCP hub:
ssh 10.0.0.3
# Direct:
ssh ubuntu@130.110.251.193
```

## Services Running
| Service | Container | Port | Network |
|---------|-----------|------|---------|
| Stalwart Mail | stalwart-mail | 587, 993, 443, 8080 | mail_network |
| Matomo (analytics) | matomo-app | 8081 | matomo_default |
| Matomo MariaDB | matomo-db | - | matomo_default |
| Matomo NPM | nginx-proxy | 80, 443, 81 | matomo_default |
| Syncthing | syncthing | 8384, 22000, 21027/udp | matomo_default |
| Sauron (security) | sauron | - | sauron_security |

## Docker Networks
- mail_network
- mailu_default
- matomo_default
- sauron-lite_security / sauron_security
- palantir-monitor_monitor
- fluent-bit_default

## OS Config Files
- `/etc/wireguard/wg0.conf` - WireGuard spoke (see wireguard-wg0.conf)
- iptables: INPUT ACCEPT (no firewall restrictions beyond Docker)

## Availability
**24/7 (FREE TIER)** - Always running, no cost

## Notes
- Mail server (Stalwart) + Matomo analytics + Syncthing
- Has its own NPM for analytics.diegonmarcos.com
