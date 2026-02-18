# gcp-t4-spot_1

## Overview
| Property | Value |
|----------|-------|
| **ID** | gcp-T4-p_0 |
| **Name** | GCP Spot T4 GPU |
| **Provider** | Google Cloud |
| **Instance Type** | n1-standard-4 + NVIDIA T4 GPU |
| **Hostname** | ollama-spot-gpu |
| **Status** | SPOT (started on demand) |

## Specs
| Resource | Value |
|----------|-------|
| **CPU** | 4 vCPU (N1) |
| **RAM** | 15 GB |
| **GPU** | NVIDIA Tesla T4 (16GB VRAM) |
| **Storage** | 50 GB |
| **Arch** | x86_64 |

## Network
| Property | Value |
|----------|-------|
| **Public IP** | 34.57.36.41 (changes on restart — spot) |
| **WireGuard IP** | 10.0.0.8 |
| **Region** | us-central1 |
| **Zone** | us-central1-a |

## OS
| Property | Value |
|----------|-------|
| **Name** | Debian 12 |
| **Arch** | x86_64 |

## SSH Access
```bash
ssh gcp-ollama
# or: gcloud compute ssh ollama-spot-gpu --zone us-central1-a
# Key: ~/git/vault/A0_keys/ssh/google_compute_engine
```

## Services Running
| Service | Container | Port | Network |
|---------|-----------|------|---------|
| Ollama LLM | ollama | 10.0.0.8:11434 | WG only |

## Notes
- Spot instance — preemptible, auto-terminated by GCP under load
- IP changes on every restart (ephemeral, not static)
- WireGuard mesh only — no public-facing ports except SSH + WireGuard
- Start via: `gcloud compute instances start ollama-spot-gpu --zone us-central1-a`
