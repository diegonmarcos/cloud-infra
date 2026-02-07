# oci-f-micro_2

## Overview
| Property | Value |
|----------|-------|
| **ID** | oci-f-micro_2 |
| **Name** | OCI Free Micro 2 |
| **Provider** | Oracle Cloud |
| **Instance Type** | VM.Standard.E2.1.Micro |
| **Hostname** | services-server |
| **OCID** | ocid1.instance.oc1.eu-marseille-1.anwxeljruadvczacgwg5rkrjyomuxvjtvtuk5xrbmy7hmslwn4pse4kw5jkq |
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
| **Public IP** | 129.151.228.66 |
| **WireGuard IP** | 10.0.0.4 |
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
ssh 10.0.0.4
# Direct:
ssh ubuntu@129.151.228.66
```

## Services Running
| Service | Container | Port | Network |
|---------|-----------|------|---------|
| Matomo Hybrid | matomo-hybrid | 8080 | matomo-hybrid_default |
| Windmill Server | windmill-server | 127.0.0.1:8000 | windmill-net |
| Windmill Worker | windmill-worker | - | windmill-net |
| Windmill Postgres | windmill-db | - | windmill-net |
| Sauron (security) | sauron | - | sauron-lite_security |
| Sauron Forwarder | sauron-forwarder | - | sauron-lite_security |

## Docker Networks
- matomo-hybrid_default
- windmill-net
- sauron-lite_security / sauron_security
- fluent-bit_default
- n8n_default
- nginx-proxy-manager_default
- orchestrator

## OS Config Files
- `/etc/wireguard/wg0.conf` - WireGuard spoke (see wireguard-wg0.conf)
- iptables: standard Docker isolation (no custom INPUT rules)

## Availability
**24/7 (FREE TIER)** - Always running, no cost

## Notes
- Matomo hybrid (sleep/wake mode for RAM savings)
- Windmill workflow orchestration
- analytics.diegonmarcos.com proxied from Micro1 NPM
