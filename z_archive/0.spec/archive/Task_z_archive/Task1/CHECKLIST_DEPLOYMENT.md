# Task1: Deployment Checklist

**Task**: Production Deployment via CLI
**Started**: 2025-12-04
**Assignee**: Sonnet
**Supervisor**: Opus
**Status**: 🚧 READY TO START

---

## Quick Status

| Phase | Status | Progress |
|-------|--------|----------|
| Phase 1: GCloud NPM | ⏳ Pending | 0% |
| Phase 2: Oracle Dev Server | ⏳ Pending | 0% |
| Phase 3: Migrate Oracle VMs | ⏳ Pending | 0% |
| Phase 4: DNS Updates | ⏳ Pending | 0% |
| Phase 5: Idle Monitor | ⏳ Pending | 0% |
| Phase 6: Verification | ⏳ Pending | 0% |
| **OVERALL** | **⏳ Pending** | **0%** |

---

## Phase 1: GCloud Arch 1 - NPM Proxy

### 1.1 Create VM
- [ ] Set GCloud project
- [ ] Run `gcloud compute instances create arch-1`
- [ ] Verify VM is RUNNING
- [ ] Record instance name: `arch-1`

### 1.2 Firewall Rules
- [ ] Create allow-http rule (port 80)
- [ ] Create allow-https rule (port 443)
- [ ] Create allow-npm-admin rule (port 81)
- [ ] Verify rules are active

### 1.3 Get External IP
- [ ] Run `gcloud compute instances describe`
- [ ] Record IP: `__________________`
- [ ] Update this checklist with IP

### 1.4 Install NPM
- [ ] SSH into arch-1
- [ ] Docker installed
- [ ] docker-compose.yml created
- [ ] NPM container running
- [ ] Verify with `docker ps`

### 1.5 Configure NPM
- [ ] Access http://<IP>:81
- [ ] Change default password
- [ ] Add proxy host: analytics.diegonmarcos.com
- [ ] Add proxy host: mail.diegonmarcos.com
- [ ] Add proxy host: sync.diegonmarcos.com
- [ ] Add proxy host: n8n.diegonmarcos.com
- [ ] Add proxy host: git.diegonmarcos.com
- [ ] Add proxy host: cloud.diegonmarcos.com
- [ ] SSL certificates obtained for all

**Phase 1 Status**: ⏳ Pending

---

## Phase 2: Oracle Dev Server - 8GB Dormant

### 2.1 Get OCIDs
- [ ] Get compartment OCID: `__________________`
- [ ] Get availability domain: `__________________`
- [ ] Get subnet OCID: `__________________`
- [ ] Get Ubuntu 24.04 image OCID: `__________________`

### 2.2 Create Instance
- [ ] Run `oci compute instance launch`
- [ ] Wait for RUNNING state
- [ ] Record instance OCID: `__________________`
- [ ] Record public IP: `__________________`

### 2.3 Update Configuration
- [ ] Update cloud_dash.json with real OCID
- [ ] Verify OCID replaced in JSON
- [ ] Commit JSON change

### 2.4 Security List
- [ ] Add port 22 (SSH)
- [ ] Add port 80 (HTTP)
- [ ] Add port 443 (HTTPS)
- [ ] Add port 5678 (n8n)
- [ ] Add port 8384 (Syncthing GUI)
- [ ] Add port 22000 TCP/UDP (Syncthing)
- [ ] Add port 21027 UDP (Syncthing discovery)
- [ ] Add port 3000 (Gitea)
- [ ] Add port 5000 (Cloud API)
- [ ] Add port 1194 UDP (VPN)

### 2.5 Install Services
- [ ] SSH into dev server
- [ ] Docker installed
- [ ] docker-compose.yml created
- [ ] n8n container running
- [ ] syncthing container running
- [ ] gitea container running
- [ ] cloud-api container running
- [ ] terminal container running
- [ ] redis container running
- [ ] vpn container running
- [ ] All 7 containers verified with `docker ps`

### 2.6 Test Wake/Stop
- [ ] Stop instance via CLI
- [ ] Verify STOPPED state
- [ ] Start instance via CLI
- [ ] Verify RUNNING state
- [ ] Services auto-start confirmed

**Phase 2 Status**: ⏳ Pending

---

## Phase 3: Migrate Existing Oracle VMs

### 3.1 Oracle Web Server 1 (130.110.251.193)
- [ ] SSH into server
- [ ] Stop old containers
- [ ] Remove old containers/images
- [ ] Create mail directory
- [ ] Deploy mail server container
- [ ] Mail server running
- [ ] Verify with `docker ps`

### 3.2 Oracle Services Server 1 (129.151.228.66)
- [ ] SSH into server
- [ ] Stop NPM container
- [ ] Remove NPM container
- [ ] Verify Matomo still running
- [ ] Verify Matomo DB still running

**Phase 3 Status**: ⏳ Pending

---

## Phase 4: DNS Updates

### 4.1 A Records (Cloudflare)
- [ ] analytics.diegonmarcos.com → GCloud IP
- [ ] sync.diegonmarcos.com → GCloud IP
- [ ] n8n.diegonmarcos.com → GCloud IP
- [ ] git.diegonmarcos.com → GCloud IP
- [ ] cloud.diegonmarcos.com → GCloud IP
- [ ] mail.diegonmarcos.com → GCloud IP

### 4.2 Mail Records
- [ ] MX record: @ → mail.diegonmarcos.com (priority 10)
- [ ] TXT record (SPF): "v=spf1 mx a ~all"
- [ ] TXT record (DMARC): _dmarc → "v=DMARC1; p=quarantine..."
- [ ] DKIM record (after mail setup)

### 4.3 DNS Propagation
- [ ] Check analytics resolves to GCloud IP
- [ ] Check n8n resolves to GCloud IP
- [ ] Check mail MX record active

**Phase 4 Status**: ⏳ Pending

---

## Phase 5: Idle Monitor Setup

### 5.1 Install Script
- [ ] SSH into dev server
- [ ] Create /usr/local/bin/idle-check.sh
- [ ] Make script executable
- [ ] Test script runs without error

### 5.2 Configure Cron
- [ ] Add cron job (every 5 minutes)
- [ ] Verify cron job listed

### 5.3 Test Auto-Stop
- [ ] Leave VM idle for 30+ minutes
- [ ] Confirm auto-shutdown triggers
- [ ] Check syslog for shutdown message

**Phase 5 Status**: ⏳ Pending

---

## Phase 6: Verification & Testing

### 6.1 GCloud NPM Tests
- [ ] HTTP to GCloud IP works
- [ ] NPM admin panel accessible
- [ ] analytics.diegonmarcos.com loads Matomo
- [ ] SSL certificates valid

### 6.2 Wake API Tests
- [ ] /api/wake/status returns correct state
- [ ] /api/wake/trigger starts VM
- [ ] Status updates to RUNNING after wake

### 6.3 Full Wake Cycle
- [ ] Stop VM via CLI
- [ ] Call wake API
- [ ] Poll until RUNNING (~60s)
- [ ] All services accessible after wake
- [ ] n8n.diegonmarcos.com responds
- [ ] sync.diegonmarcos.com responds
- [ ] git.diegonmarcos.com responds

### 6.4 Service Health
- [ ] Matomo tracking working
- [ ] Mail server receiving (test email)
- [ ] n8n workflows accessible
- [ ] Syncthing GUI accessible
- [ ] Gitea web UI accessible
- [ ] Cloud API responding

### 6.5 Cost Verification
- [ ] GCloud shows $0 billing (free tier)
- [ ] Oracle shows minimal cost (dormant hours only)
- [ ] Estimated monthly: $5-7

**Phase 6 Status**: ⏳ Pending

---

## Captured Values

Fill in as you go:

| Item | Value |
|------|-------|
| GCloud Project ID | |
| GCloud Arch 1 IP | |
| OCI Compartment OCID | |
| OCI Subnet OCID | |
| OCI Image OCID | |
| Dev Server Instance OCID | |
| Dev Server IP | |
| Cloudflare Zone ID | |

---

## Issues / Notes

| Date | Issue | Resolution |
|------|-------|------------|
| | | |

---

## Sign-off

| Role | Name | Date | Signature |
|------|------|------|-----------|
| Developer | Sonnet | | ⬜ Pending |
| Architect | Opus | | ⬜ Pending |
| CEO | Diego | | ⬜ Pending |

---

## Time Tracking

| Phase | Estimated | Actual | Status |
|-------|-----------|--------|--------|
| Phase 1: GCloud NPM | 45 min | - | ⏳ |
| Phase 2: Oracle Dev Server | 60 min | - | ⏳ |
| Phase 3: Migrate VMs | 30 min | - | ⏳ |
| Phase 4: DNS Updates | 15 min | - | ⏳ |
| Phase 5: Idle Monitor | 20 min | - | ⏳ |
| Phase 6: Verification | 30 min | - | ⏳ |
| **TOTAL** | **~3.5 hours** | **-** | **⏳** |

---

**Last Updated**: 2025-12-04
**Next Step**: Start Phase 1 - GCloud NPM Setup
