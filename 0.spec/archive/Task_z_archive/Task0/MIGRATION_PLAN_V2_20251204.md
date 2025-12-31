# Migration Plan: Architecture v1 → v2

**Date**: 2025-12-04
**Status**: READY FOR EXECUTION
**Risk Level**: Medium (requires service downtime)

---

## Migration Overview

### Current State (v1)
```
Oracle Web 1:     NPM + n8n + Syncthing + Cloud + VPN + Gitea + Redis
Oracle Services 1: NPM + Matomo + Matomo DB
GCloud Arch 1:    Not deployed
Oracle ARM:       Pending approval (not used)
```

### Target State (v2)
```
GCloud Arch 1:    NPM (central proxy)
Oracle Web 1:     Mail + Mail DB
Oracle Services 1: Matomo + Matomo DB (no NPM)
Oracle Paid 8GB:  n8n + Syncthing + Gitea + Cloud + VPN + Redis + Terminal
```

---

## Pre-Migration Checklist

- [ ] Backup all data (Syncthing, Matomo DB, configs)
- [ ] Document current NPM proxy configurations
- [ ] Export NPM SSL certificates
- [ ] Note all DNS records
- [ ] Test SSH access to all VMs
- [ ] Have OCI CLI configured
- [ ] Have GCloud CLI configured
- [ ] Schedule maintenance window (recommend: 2-4 hours)

---

## Phase 1: Setup GCloud Arch 1 (New NPM)

**Duration**: 30-45 minutes
**Downtime**: None (parallel setup)

### Step 1.1: Deploy GCloud VM
```bash
# Create VM
gcloud compute instances create arch-1 \
  --zone=us-central1-a \
  --machine-type=e2-micro \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=30GB \
  --tags=http-server,https-server

# Get external IP
gcloud compute instances describe arch-1 \
  --zone=us-central1-a \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)'
```

### Step 1.2: Configure Firewall
```bash
# Allow HTTP/HTTPS/NPM Admin
gcloud compute firewall-rules create allow-web \
  --allow tcp:80,tcp:443,tcp:81 \
  --target-tags=http-server,https-server
```

### Step 1.3: Install Docker & NPM
```bash
# SSH into GCloud VM
gcloud compute ssh arch-1 --zone=us-central1-a

# Install Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER

# Create NPM docker-compose.yml
mkdir -p ~/npm && cd ~/npm
cat > docker-compose.yml << 'EOF'
version: '3.8'
services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    container_name: npm
    restart: always
    ports:
      - "80:80"
      - "443:443"
      - "81:81"
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    environment:
      - DISABLE_IPV6=true
EOF

# Start NPM
docker compose up -d
```

### Step 1.4: Configure NPM
1. Access NPM admin: `http://<GCLOUD_IP>:81`
2. Default login: `admin@example.com` / `changeme`
3. Change password immediately
4. Import SSL certificates from old NPM (or request new ones)

### Step 1.5: Verify NPM Running
```bash
curl -I http://<GCLOUD_IP>
# Should return NPM response
```

---

## Phase 2: Create Oracle Paid VM (Dormant Services)

**Duration**: 30-45 minutes
**Downtime**: None (parallel setup)

### Step 2.1: Create E4.Flex Instance
```bash
# Create instance with 1 OCPU + 8GB RAM
oci compute instance launch \
  --availability-domain "EU-MARSEILLE-1-AD-1" \
  --compartment-id $OCI_COMPARTMENT_ID \
  --shape "VM.Standard.E4.Flex" \
  --shape-config '{"ocpus": 1, "memoryInGBs": 8}' \
  --image-id <UBUNTU_24_IMAGE_OCID> \
  --subnet-id $OCI_SUBNET_ID \
  --assign-public-ip true \
  --display-name "oracle-dev-server" \
  --ssh-authorized-keys-file ~/.ssh/id_rsa.pub
```

### Step 2.2: Configure Security List
Open ports in OCI Console or CLI:
- 22 (SSH)
- 80, 443 (HTTP/HTTPS - for direct access if needed)
- 5678 (n8n)
- 8384, 22000, 21027 (Syncthing)
- 3000, 2222 (Gitea)
- 5000 (Cloud API)
- 1194/UDP (VPN)
- 6379 (Redis - internal only)

### Step 2.3: Install Docker
```bash
ssh ubuntu@<NEW_VM_IP>

# Install Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker ubuntu

# Create docker network
docker network create dev_network
```

### Step 2.4: Create Docker Compose for All Services
```bash
mkdir -p ~/services && cd ~/services
cat > docker-compose.yml << 'EOF'
version: '3.8'

services:
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    ports:
      - "5678:5678"
    volumes:
      - ./n8n_data:/home/node/.n8n
    environment:
      - N8N_HOST=n8n.diegonmarcos.com
      - N8N_PROTOCOL=https
      - WEBHOOK_URL=https://n8n.diegonmarcos.com/
    networks:
      - dev_network

  syncthing:
    image: syncthing/syncthing:latest
    container_name: syncthing
    restart: unless-stopped
    ports:
      - "8384:8384"
      - "22000:22000/tcp"
      - "22000:22000/udp"
      - "21027:21027/udp"
    volumes:
      - ./syncthing_config:/var/syncthing/config
      - ./syncthing_data:/var/syncthing/data
    environment:
      - PUID=1000
      - PGID=1000
    networks:
      - dev_network

  gitea:
    image: gitea/gitea:latest
    container_name: gitea
    restart: unless-stopped
    ports:
      - "3000:3000"
      - "2222:22"
    volumes:
      - ./gitea_data:/data
    environment:
      - GITEA__server__ROOT_URL=https://git.diegonmarcos.com/
      - GITEA__server__SSH_PORT=2222
      - GITEA__server__SSH_DOMAIN=git.diegonmarcos.com
    networks:
      - dev_network

  cloud-api:
    image: python:3.11-slim
    container_name: cloud-api
    restart: unless-stopped
    ports:
      - "5000:5000"
    volumes:
      - ./cloud_api:/app
    working_dir: /app
    command: python -m flask run --host=0.0.0.0
    environment:
      - FLASK_APP=cloud_dash.py
      - FLASK_ENV=production
    networks:
      - dev_network

  terminal:
    image: wettyoss/wetty:latest
    container_name: terminal
    restart: unless-stopped
    ports:
      - "3001:3000"
    environment:
      - SSHHOST=host.docker.internal
      - SSHPORT=22
    networks:
      - dev_network

  redis:
    image: redis:alpine
    container_name: redis
    restart: unless-stopped
    ports:
      - "6379:6379"
    volumes:
      - ./redis_data:/data
    networks:
      - dev_network

  vpn:
    image: kylemanna/openvpn:latest
    container_name: vpn
    restart: unless-stopped
    ports:
      - "1194:1194/udp"
    volumes:
      - ./vpn_data:/etc/openvpn
    cap_add:
      - NET_ADMIN
    networks:
      - dev_network

networks:
  dev_network:
    external: true
EOF
```

### Step 2.5: Start Services
```bash
docker compose up -d
```

---

## Phase 3: Migrate Data

**Duration**: 30-60 minutes
**Downtime**: Partial (services being migrated)

### Step 3.1: Migrate n8n Data
```bash
# On Oracle Web 1 (source)
cd ~/n8n
docker compose stop n8n
tar -czvf n8n_backup.tar.gz data/

# Transfer to new VM
scp n8n_backup.tar.gz ubuntu@<NEW_VM_IP>:~/services/

# On new VM (destination)
cd ~/services
tar -xzvf n8n_backup.tar.gz
mv data n8n_data
docker compose up -d n8n
```

### Step 3.2: Migrate Syncthing Data
```bash
# On Oracle Web 1 (source)
cd ~/syncthing
docker compose stop syncthing
tar -czvf syncthing_backup.tar.gz config/ data/

# Transfer to new VM
scp syncthing_backup.tar.gz ubuntu@<NEW_VM_IP>:~/services/

# On new VM (destination)
cd ~/services
tar -xzvf syncthing_backup.tar.gz
mv config syncthing_config
mv data syncthing_data
docker compose up -d syncthing
```

### Step 3.3: Migrate Gitea Data (if exists)
```bash
# Similar process - backup, transfer, restore
```

### Step 3.4: Migrate Cloud API
```bash
# Copy Flask app files
scp -r ~/cloud_api ubuntu@<NEW_VM_IP>:~/services/cloud_api/
```

---

## Phase 4: Setup Mail Server on Oracle Web 1

**Duration**: 45-60 minutes
**Downtime**: None (new service)

### Step 4.1: Clean Oracle Web 1
```bash
# Stop and remove old services (after data migration confirmed)
ssh ubuntu@130.110.251.193

cd ~/
docker compose down
docker system prune -a

# Keep only what's needed for mail
```

### Step 4.2: Install Mail Server
```bash
mkdir -p ~/mail && cd ~/mail
cat > docker-compose.yml << 'EOF'
version: '3.8'

services:
  mailserver:
    image: docker.io/mailserver/docker-mailserver:latest
    container_name: mailserver
    hostname: mail
    domainname: diegonmarcos.com
    restart: always
    ports:
      - "25:25"
      - "587:587"
      - "993:993"
    volumes:
      - ./mail-data:/var/mail
      - ./mail-state:/var/mail-state
      - ./mail-logs:/var/log/mail
      - ./config:/tmp/docker-mailserver
      - /etc/localtime:/etc/localtime:ro
    environment:
      - ENABLE_SPAMASSASSIN=1
      - ENABLE_CLAMAV=0
      - ENABLE_FAIL2BAN=1
      - SSL_TYPE=letsencrypt
      - PERMIT_DOCKER=network
    cap_add:
      - NET_ADMIN
      - SYS_PTRACE
EOF

docker compose up -d
```

### Step 4.3: Configure DNS for Mail
Add to Cloudflare:
```
MX    @              mail.diegonmarcos.com    10
A     mail           130.110.251.193
TXT   @              "v=spf1 mx a ~all"
TXT   _dmarc         "v=DMARC1; p=quarantine; rua=mailto:postmaster@diegonmarcos.com"
```

---

## Phase 5: Remove NPM from Oracle Services 1

**Duration**: 15 minutes
**Downtime**: Brief (NPM switch)

### Step 5.1: Update DNS to Point to GCloud NPM
In Cloudflare, update A records to point to GCloud IP:
```
A     @              <GCLOUD_IP>
A     analytics      <GCLOUD_IP>
A     sync           <GCLOUD_IP>
A     n8n            <GCLOUD_IP>
A     git            <GCLOUD_IP>
A     cloud          <GCLOUD_IP>
A     terminal       <GCLOUD_IP>
```

### Step 5.2: Configure GCloud NPM Proxy Hosts
In NPM Admin, add proxy hosts:

| Domain | Forward IP | Port | SSL |
|--------|------------|------|-----|
| analytics.diegonmarcos.com | 129.151.228.66 | 8080 | Let's Encrypt |
| mail.diegonmarcos.com | 130.110.251.193 | 587 | Let's Encrypt |
| sync.diegonmarcos.com | <PAID_VM_IP> | 8384 | Let's Encrypt |
| n8n.diegonmarcos.com | <PAID_VM_IP> | 5678 | Let's Encrypt |
| git.diegonmarcos.com | <PAID_VM_IP> | 3000 | Let's Encrypt |
| cloud.diegonmarcos.com | <PAID_VM_IP> | 5000 | Let's Encrypt |

### Step 5.3: Remove NPM from Oracle Services 1
```bash
ssh ubuntu@129.151.228.66

# Stop NPM container
docker stop npm-oracle-services
docker rm npm-oracle-services

# Update docker-compose to remove NPM
# Keep only Matomo services
```

---

## Phase 6: Setup Wake-on-Demand System

**Duration**: 45-60 minutes
**Downtime**: None

### Step 6.1: Create OCI Function for Wake
```python
# func.py
import io
import json
import oci
from fdk import response

def handler(ctx, data: io.BytesIO = None):
    signer = oci.auth.signers.get_resource_principals_signer()
    compute_client = oci.core.ComputeClient(config={}, signer=signer)

    instance_id = "ocid1.instance.oc1.eu-marseille-1.xxx"  # Your paid VM OCID

    # Get current state
    instance = compute_client.get_instance(instance_id).data

    if instance.lifecycle_state == "STOPPED":
        # Start the instance
        compute_client.instance_action(instance_id, "START")
        return response.Response(
            ctx,
            response_data=json.dumps({"status": "starting", "wait": 60}),
            headers={"Content-Type": "application/json"}
        )
    elif instance.lifecycle_state == "RUNNING":
        return response.Response(
            ctx,
            response_data=json.dumps({"status": "running"}),
            headers={"Content-Type": "application/json"}
        )
    else:
        return response.Response(
            ctx,
            response_data=json.dumps({"status": instance.lifecycle_state}),
            headers={"Content-Type": "application/json"}
        )
```

### Step 6.2: Create Idle Monitor Script on Paid VM
```bash
# /usr/local/bin/idle-check.sh
#!/bin/bash

IDLE_THRESHOLD=1800  # 30 minutes in seconds
LOG_FILE="/var/log/nginx/access.log"

# Get last access time
if [ -f "$LOG_FILE" ]; then
    LAST_ACCESS=$(stat -c %Y "$LOG_FILE")
    CURRENT_TIME=$(date +%s)
    IDLE_TIME=$((CURRENT_TIME - LAST_ACCESS))

    if [ $IDLE_TIME -gt $IDLE_THRESHOLD ]; then
        logger "Idle timeout reached ($IDLE_TIME seconds). Shutting down."
        /sbin/shutdown now
    fi
fi
```

### Step 6.3: Add Cron Job
```bash
# Add to crontab
*/5 * * * * /usr/local/bin/idle-check.sh
```

---

## Phase 7: Verification & Testing

**Duration**: 30 minutes

### Test Checklist

- [ ] GCloud NPM accessible on port 81
- [ ] analytics.diegonmarcos.com loads Matomo
- [ ] mail.diegonmarcos.com accepts connections (port 587)
- [ ] Dormant VM starts when accessing sync/n8n/git/cloud
- [ ] Dormant VM stops after idle timeout
- [ ] All SSL certificates valid
- [ ] No services on wrong VMs

### Rollback Plan

If migration fails:
1. Revert DNS to old Oracle Web 1 NPM IP
2. Start old services on Oracle Web 1
3. Investigate and fix issues
4. Retry migration

---

## Post-Migration Tasks

- [ ] Update cloud_dash.json with new architecture
- [ ] Update monitoring dashboards
- [ ] Document new SSH commands
- [ ] Test wake-on-demand from mobile
- [ ] Set up alerts for VM state changes
- [ ] Remove old Docker images from Oracle VMs

---

## Timeline Summary

| Phase | Duration | Downtime |
|-------|----------|----------|
| Phase 1: GCloud NPM | 45 min | None |
| Phase 2: Paid VM Setup | 45 min | None |
| Phase 3: Data Migration | 60 min | Partial |
| Phase 4: Mail Server | 60 min | None |
| Phase 5: NPM Switch | 15 min | ~5 min |
| Phase 6: Wake System | 60 min | None |
| Phase 7: Testing | 30 min | None |
| **Total** | **~5-6 hours** | **~5-10 min** |

---

## Emergency Contacts

- Oracle Cloud Support: https://support.oracle.com
- GCloud Support: https://cloud.google.com/support
- Cloudflare Status: https://cloudflarestatus.com
