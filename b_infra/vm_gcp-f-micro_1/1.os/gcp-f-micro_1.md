# gcp-f-micro_1

## Overview
| Property | Value |
|----------|-------|
| **ID** | gcp-f-micro_1 |
| **Name** | GCP Free Micro 1 |
| **Provider** | Google Cloud |
| **Instance Type** | e2-micro |
| **Status** | DEV (Pending) |

## Specs
| Resource | Value |
|----------|-------|
| **CPU** | 0.25-2 vCPU |
| **RAM** | 1 GB |
| **Storage** | 30 GB |

## Network
| Property | Value |
|----------|-------|
| **Public IP** | pending |
| **Private IP** | pending |
| **Region** | us-central1 |
| **Zone** | us-central1-a |

## OS
| Property | Value |
|----------|-------|
| **Name** | Arch Linux |
| **Version** | rolling |

## SSH Access
```bash
gcloud compute ssh arch-1 --zone us-central1-a
```

## Services Planned
| Service | Port | Status |
|---------|------|--------|
| mail-app | 25, 587, 993 | DEV |
| mail-db | - | DEV |
| terminal-app | 7681 | DEV |
| npm-gcloud | 81 | DEV |

## Ports
**External:** 22, 80, 443, 81, 25, 587, 993
**Internal:** 8025, 7681

## Resource Usage
| Resource | Min | Max |
|----------|-----|-----|
| RAM | 800 MB | 1.5 GB |
| Storage | 10 GB | 50 GB |
| Bandwidth | 5 GB/mo | 15 GB/mo |

## Budget Protection
- Billing disabler Cloud Function enabled
- Budget alerts configured
- See `2.app/billing-disabler/` for implementation

## Notes
Mail server + Web Terminal on Arch Linux
