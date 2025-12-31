# oci-f-micro_2

## Overview
| Property | Value |
|----------|-------|
| **ID** | oci-f-micro_2 |
| **Name** | OCI Free Micro 2 |
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
| **Public IP** | 129.151.228.66 |
| **Private IP** | 10.0.0.x |
| **Region** | eu-marseille-1 |

## OS
| Property | Value |
|----------|-------|
| **Name** | Ubuntu |
| **Version** | 24.04 LTS |

## SSH Access
```bash
ssh ubuntu@129.151.228.66
```

## OCI Instance ID
```
ocid1.instance.oc1.eu-marseille-1.anwxeljruadvczacgwg5rkrjyomuxvjtvtuk5xrbmy7hmslwn4pse4kw5jkq
```

## Services Running
| Service | Port | Status |
|---------|------|--------|
| analytics-app | 8080 | ON |
| analytics-db | 3306 | ON |
| cloud-db | - | DEV |
| npm-oracle-services | 81 | ON |

## Ports
**External:** 22, 80, 443, 81
**Internal:** 8080, 3306

## Resource Usage
| Resource | Min | Max |
|----------|-----|-----|
| RAM | 600 MB | 1.2 GB |
| Storage | 5 GB | 15 GB |
| Bandwidth | 5 GB/mo | 20 GB/mo |

## Notes
Matomo Analytics + Cloud_Dashboard-db
