# oci-p-flex_2

## Overview
| Property | Value |
|----------|-------|
| **ID** | oci-A1-p_0 |
| **Name** | OCI Paid Flex 2 |
| **Provider** | Oracle Cloud |
| **Instance Type** | VM.Standard.A1.Flex (8 OCPU, 32GB) |
| **Hostname** | oci-apps-2 |
| **Status** | PRODUCTION |

## Specs
| Resource | Value |
|----------|-------|
| **CPU** | 8 OCPU (Ampere A1 ARM) |
| **RAM** | 32 GB |
| **Storage** | 200 GB |
| **Arch** | aarch64 (ARM64) |

## Network
| Property | Value |
|----------|-------|
| **Public IP** | 79.72.28.10 |
| **WireGuard IP** | 10.0.0.7 |
| **Region** | eu-marseille-1 |

## OS
| Property | Value |
|----------|-------|
| **Name** | Ubuntu 24.04 LTS |
| **Arch** | aarch64 |

## SSH Access
```bash
ssh oci-apps-2
# Key: ~/git/vault/A0_keys/ssh/oci_key
```

## Notes
- ARM64 (aarch64) — all images must support arm64
- On-demand compute (largest A1.Flex instance in tenancy)
- WireGuard mesh only — no public-facing ports except SSH + WireGuard
