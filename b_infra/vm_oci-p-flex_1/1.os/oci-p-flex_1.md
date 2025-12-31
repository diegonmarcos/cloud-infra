# oci-p-flex_1

## Overview
| Property | Value |
|----------|-------|
| **ID** | oci-p-flex_1 |
| **Name** | OCI Paid Flex 1 |
| **Provider** | Oracle Cloud |
| **Instance Type** | VM.Standard.E4.Flex |
| **Status** | Wake-on-Demand |
| **Availability** | PAID (~$5.50/mo) |

## Specs
| Resource | Value |
|----------|-------|
| **CPU** | 1 OCPU (2 vCPU AMD) |
| **RAM** | 8 GB |
| **Storage** | 100 GB Boot |

## Network
| Property | Value |
|----------|-------|
| **Public IP** | 84.235.234.87 |
| **Private IP** | 10.0.0.x |
| **Region** | eu-marseille-1 |
| **Docker Network** | dev_network (172.24.0.0/24) |

## OS
| Property | Value |
|----------|-------|
| **Name** | Ubuntu |
| **Version** | 22.04 LTS |

## SSH Access
```bash
ssh ubuntu@84.235.234.87
```

## Services Running
| Service | Port | Status |
|---------|------|--------|
| n8n-infra-app | 5678 | ON |
| sync-app | 8384 | ON |
| cloud-app | 80 | ON |
| flask-app | 5000 | DEV |
| git-app | 3000 | DEV |
| vpn-app | 1194 | DEV |
| terminal-app | 7681 | DEV |
| cache-app | 6379 | DEV |

## Databases
| Database | Port | Status |
|----------|------|--------|
| cloud-db | 5432 | DEV |
| git-db | 5432 | DEV |

## Ports
**External:** 22, 80, 443, 22000, 21027, 1194, 2222
**Internal:** 5678, 8384, 5000, 3000, 7681, 6379, 5432

## Resource Usage
| Resource | Min | Max |
|----------|-----|-----|
| RAM | 2 GB | 6 GB |
| Storage | 10 GB | 50 GB |

## Wake-on-Demand Architecture
This VM is **NOT always-on** to save costs:
- Stays **dormant** by default
- Only started when services are needed
- Reduces monthly cost from ~$50+ to ~$5.50/mo
- Heavy services (n8n, sync, git, cloud) run here instead of free-tier VMs

### Auto-Shutdown (Idle Detection)
**Script:** `/opt/scripts/idle-shutdown.sh`
**Timer:** `idle-shutdown.timer` (runs every 5 minutes)
**Timeout:** 30 minutes (1800 seconds) of inactivity

**Idle conditions (all must be true):**
- No active SSH sessions
- CPU usage < 10%
- No Docker containers using > 5% CPU
- No active Syncthing transfers
- No active n8n workflow executions
- Network traffic < 100 KB/s

**Logs:** `/var/log/idle-shutdown.log`

**Commands:**
```bash
# Check timer status
systemctl status idle-shutdown.timer

# View idle logs
tail -f /var/log/idle-shutdown.log

# Reset idle timer (keep VM running)
sudo rm /var/run/idle-shutdown-state

# Disable auto-shutdown temporarily
sudo systemctl stop idle-shutdown.timer

# Re-enable auto-shutdown
sudo systemctl start idle-shutdown.timer
```

## Notes
Wake-on-Demand development server for heavy workloads: n8n (Infra) + Syncthing + Cloud Dashboard + Git + VPN + Terminal + Cache
