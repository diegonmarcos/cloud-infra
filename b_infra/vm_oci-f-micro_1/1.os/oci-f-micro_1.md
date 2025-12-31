# oci-f-micro_1

## Overview
| Property | Value |
|----------|-------|
| **ID** | oci-f-micro_1 |
| **Name** | OCI Free Micro 1 |
| **Provider** | Oracle Cloud |
| **Instance Type** | VM.Standard.E2.1.Micro |
| **Status** | Active |

## Specs
| Resource | Value |
|----------|-------|
| **CPU** | 1 OCPU (AMD) |
| **RAM** | 1 GB |
| **Storage** | 47 GB Boot |

## Network
| Property | Value |
|----------|-------|
| **Public IP** | 130.110.251.193 |
| **Private IP** | 10.0.0.x |
| **Region** | eu-marseille-1 |

## OS
| Property | Value |
|----------|-------|
| **Name** | Ubuntu |
| **Version** | 24.04 LTS |

## SSH Access
```bash
ssh ubuntu@130.110.251.193
```

## OCI Instance ID
```
ocid1.instance.oc1.eu-marseille-1.anwxeljruadvczacbwylmkqr253ay7binepapgsyopllfayovkzaky6oigbq
```

## Services Running
| Service | Port | Status |
|---------|------|--------|
| mail-app | 25, 587, 993 | DEV |
| npm-oracle-web | 81 | ON |

## Databases
| Database | Port | Status |
|----------|------|--------|
| mail-db | - | DEV |

## Ports
**External:** 22, 80, 443, 25, 587, 993
**Internal:** 81

## Resource Usage
| Resource | Min | Max |
|----------|-----|-----|
| RAM | 200 MB | 800 MB |
| Storage | 2 GB | 10 GB |
| Bandwidth | 5 GB/mo | 30 GB/mo |

## Availability
**24/7 (FREE TIER)** - Always running, no cost

## Notes
Mail server (docker-mailserver) + NPM proxy. Lightweight 24/7 services only.
