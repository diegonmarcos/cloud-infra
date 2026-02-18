# Task1: Production Deployment via CLI

**Date**: 2025-12-04
**Assignee**: Sonnet
**Supervisor**: Opus (Architect)
**Approver**: Diego (CEO)
**Status**: 🚧 READY TO START

---

## Overview

Deploy Architecture v2 to production using CLI tools only:
- **GCloud CLI** (`gcloud`) - Deploy NPM proxy VM
- **OCI CLI** (`oci`) - Create paid dormant VM + configure existing VMs

**Prerequisites**:
- GCloud CLI installed and authenticated
- OCI CLI installed and authenticated
- SSH keys configured

---

## Phase 1: GCloud Arch 1 - NPM Proxy (24/7 Free)

### 1.1 Create VM Instance

```bash
# Set project (if not default)
gcloud config set project <YOUR_PROJECT_ID>

# Create e2-micro instance (free tier eligible)
gcloud compute instances create arch-1 \
  --zone=us-central1-a \
  --machine-type=e2-micro \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=30GB \
  --boot-disk-type=pd-standard \
  --tags=http-server,https-server,npm-admin \
  --metadata=startup-script='#!/bin/bash
    apt-get update
    apt-get install -y docker.io docker-compose
    systemctl enable docker
    systemctl start docker
    usermod -aG docker ubuntu'
```

### 1.2 Create Firewall Rules

```bash
# Allow HTTP (80)
gcloud compute firewall-rules create allow-http \
  --allow=tcp:80 \
  --target-tags=http-server \
  --description="Allow HTTP traffic"

# Allow HTTPS (443)
gcloud compute firewall-rules create allow-https \
  --allow=tcp:443 \
  --target-tags=https-server \
  --description="Allow HTTPS traffic"

# Allow NPM Admin (81)
gcloud compute firewall-rules create allow-npm-admin \
  --allow=tcp:81 \
  --target-tags=npm-admin \
  --source-ranges=<YOUR_IP>/32 \
  --description="Allow NPM admin from your IP only"
```

### 1.3 Get External IP

```bash
# Get the external IP
gcloud compute instances describe arch-1 \
  --zone=us-central1-a \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)'

# Save to variable
GCLOUD_IP=$(gcloud compute instances describe arch-1 \
  --zone=us-central1-a \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)')
echo "GCloud IP: $GCLOUD_IP"
```

### 1.4 SSH and Install NPM

```bash
# SSH into instance
gcloud compute ssh arch-1 --zone=us-central1-a

# Once inside the VM:
# Create NPM directory
mkdir -p ~/npm && cd ~/npm

# Create docker-compose.yml
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

# Verify running
docker ps

# Exit SSH
exit
```

### 1.5 Configure NPM Proxy Hosts

```bash
# Access NPM admin panel
echo "Open in browser: http://$GCLOUD_IP:81"
echo "Default login: admin@example.com / changeme"
```

**NPM Proxy Hosts to Add**:

| Domain | Forward Host | Port | SSL |
|--------|--------------|------|-----|
| analytics.diegonmarcos.com | 129.151.228.66 | 8080 | Let's Encrypt |
| mail.diegonmarcos.com | 130.110.251.193 | - | Let's Encrypt |
| sync.diegonmarcos.com | <DEV_SERVER_IP> | 8384 | Let's Encrypt |
| n8n.diegonmarcos.com | <DEV_SERVER_IP> | 5678 | Let's Encrypt |
| git.diegonmarcos.com | <DEV_SERVER_IP> | 3000 | Let's Encrypt |
| cloud.diegonmarcos.com | <DEV_SERVER_IP> | 5000 | Let's Encrypt |

---

## Phase 2: Oracle Dev Server - 8GB Dormant VM

### 2.1 Get Required OCIDs

```bash
# Get compartment OCID
oci iam compartment list --query 'data[0].id' --raw-output

# Save to variable
COMPARTMENT_ID=$(oci iam compartment list --query 'data[0].id' --raw-output)
echo "Compartment: $COMPARTMENT_ID"

# Get availability domain
oci iam availability-domain list \
  --compartment-id $COMPARTMENT_ID \
  --query 'data[0].name' --raw-output

AD_NAME=$(oci iam availability-domain list \
  --compartment-id $COMPARTMENT_ID \
  --query 'data[0].name' --raw-output)
echo "AD: $AD_NAME"

# Get subnet OCID (use existing from web server)
oci network subnet list \
  --compartment-id $COMPARTMENT_ID \
  --query 'data[0].id' --raw-output

SUBNET_ID=$(oci network subnet list \
  --compartment-id $COMPARTMENT_ID \
  --query 'data[0].id' --raw-output)
echo "Subnet: $SUBNET_ID"

# Get Ubuntu 24.04 image OCID for eu-marseille-1
oci compute image list \
  --compartment-id $COMPARTMENT_ID \
  --operating-system "Canonical Ubuntu" \
  --operating-system-version "24.04" \
  --shape "VM.Standard.E4.Flex" \
  --query 'data[0].id' --raw-output

IMAGE_ID=$(oci compute image list \
  --compartment-id $COMPARTMENT_ID \
  --operating-system "Canonical Ubuntu" \
  --operating-system-version "24.04" \
  --shape "VM.Standard.E4.Flex" \
  --query 'data[0].id' --raw-output)
echo "Image: $IMAGE_ID"
```

### 2.2 Create E4.Flex Instance (1 OCPU + 8GB)

```bash
# Create the instance
oci compute instance launch \
  --compartment-id $COMPARTMENT_ID \
  --availability-domain "$AD_NAME" \
  --shape "VM.Standard.E4.Flex" \
  --shape-config '{"ocpus": 1, "memoryInGBs": 8}' \
  --image-id $IMAGE_ID \
  --subnet-id $SUBNET_ID \
  --assign-public-ip true \
  --display-name "oracle-dev-server" \
  --ssh-authorized-keys-file ~/.ssh/id_rsa.pub \
  --wait-for-state RUNNING

# Get instance OCID
DEV_INSTANCE_ID=$(oci compute instance list \
  --compartment-id $COMPARTMENT_ID \
  --display-name "oracle-dev-server" \
  --query 'data[0].id' --raw-output)
echo "Instance ID: $DEV_INSTANCE_ID"

# Get public IP
DEV_SERVER_IP=$(oci compute instance list-vnics \
  --instance-id $DEV_INSTANCE_ID \
  --query 'data[0]."public-ip"' --raw-output)
echo "Dev Server IP: $DEV_SERVER_IP"
```

### 2.3 Update cloud_dash.json with Real OCID

```bash
# Update the placeholder in cloud_dash.json
sed -i "s|ocid1.instance.oc1.eu-marseille-1.PLACEHOLDER|$DEV_INSTANCE_ID|g" \
  /home/diego/Documents/Git/back-System/cloud/0.spec/cloud_dash.json

# Verify
grep "ociInstanceId" /home/diego/Documents/Git/back-System/cloud/0.spec/cloud_dash.json
```

### 2.4 Configure Security List (Open Ports)

```bash
# Get security list OCID
SECURITY_LIST_ID=$(oci network security-list list \
  --compartment-id $COMPARTMENT_ID \
  --query 'data[0].id' --raw-output)

# Add ingress rules for dev services
# Note: This adds to existing rules
oci network security-list update \
  --security-list-id $SECURITY_LIST_ID \
  --ingress-security-rules '[
    {"protocol": "6", "source": "0.0.0.0/0", "tcpOptions": {"destinationPortRange": {"min": 22, "max": 22}}},
    {"protocol": "6", "source": "0.0.0.0/0", "tcpOptions": {"destinationPortRange": {"min": 80, "max": 80}}},
    {"protocol": "6", "source": "0.0.0.0/0", "tcpOptions": {"destinationPortRange": {"min": 443, "max": 443}}},
    {"protocol": "6", "source": "0.0.0.0/0", "tcpOptions": {"destinationPortRange": {"min": 5678, "max": 5678}}},
    {"protocol": "6", "source": "0.0.0.0/0", "tcpOptions": {"destinationPortRange": {"min": 8384, "max": 8384}}},
    {"protocol": "6", "source": "0.0.0.0/0", "tcpOptions": {"destinationPortRange": {"min": 3000, "max": 3000}}},
    {"protocol": "6", "source": "0.0.0.0/0", "tcpOptions": {"destinationPortRange": {"min": 5000, "max": 5000}}},
    {"protocol": "6", "source": "0.0.0.0/0", "tcpOptions": {"destinationPortRange": {"min": 22000, "max": 22000}}},
    {"protocol": "17", "source": "0.0.0.0/0", "udpOptions": {"destinationPortRange": {"min": 21027, "max": 21027}}},
    {"protocol": "17", "source": "0.0.0.0/0", "udpOptions": {"destinationPortRange": {"min": 1194, "max": 1194}}}
  ]' \
  --force
```

### 2.5 SSH and Install Docker + Services

```bash
# SSH into dev server
ssh ubuntu@$DEV_SERVER_IP

# Install Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker ubuntu

# Logout and login to apply group
exit
ssh ubuntu@$DEV_SERVER_IP

# Create services directory
mkdir -p ~/services && cd ~/services

# Create docker-compose.yml with all dev services
cat > docker-compose.yml << 'EOF'
version: '3.8'

networks:
  dev_network:
    driver: bridge

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
    command: sh -c "pip install flask flask-cors && python -m flask run --host=0.0.0.0"
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
      - SSHHOST=172.17.0.1
      - SSHPORT=22
      - SSHUSER=ubuntu
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
EOF

# Start all services
docker compose up -d

# Verify all running
docker ps

# Exit SSH
exit
```

### 2.6 Test Wake/Stop Cycle

```bash
# Stop the instance (go dormant)
oci compute instance action \
  --instance-id $DEV_INSTANCE_ID \
  --action STOP \
  --wait-for-state STOPPED

echo "Instance stopped. Cost now: $0/hour"

# Start the instance (wake up)
oci compute instance action \
  --instance-id $DEV_INSTANCE_ID \
  --action START \
  --wait-for-state RUNNING

echo "Instance running. Cost now: ~$0.037/hour"

# Check status
oci compute instance get \
  --instance-id $DEV_INSTANCE_ID \
  --query 'data."lifecycle-state"' --raw-output
```

---

## Phase 3: Migrate Existing Oracle VMs

### 3.1 Oracle Web Server 1 - Remove Old Services

```bash
# SSH into Oracle Web 1
ssh ubuntu@130.110.251.193

# Stop and remove old services (n8n, syncthing, etc.)
cd ~/
docker compose down

# Keep only what's needed or start fresh for mail
# Remove old containers
docker system prune -a

# Exit
exit
```

### 3.2 Oracle Web Server 1 - Install Mail Server

```bash
# SSH back in
ssh ubuntu@130.110.251.193

# Create mail directory
mkdir -p ~/mail && cd ~/mail

# Create docker-compose.yml for mail
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

# Start mail server
docker compose up -d

# Exit
exit
```

### 3.3 Oracle Services Server 1 - Remove NPM

```bash
# SSH into Oracle Services 1
ssh ubuntu@129.151.228.66

# Stop NPM container (keep Matomo)
docker stop npm-oracle-services
docker rm npm-oracle-services

# Verify Matomo still running
docker ps

# Exit
exit
```

---

## Phase 4: Update DNS Records

### 4.1 Cloudflare DNS Updates

```bash
# Using Cloudflare API or Dashboard
# Update A records to point to GCloud NPM IP

# Get your Cloudflare Zone ID and API token first
CF_ZONE_ID="<your-zone-id>"
CF_API_TOKEN="<your-api-token>"
GCLOUD_IP="<gcloud-arch-1-ip>"

# Update main domain
curl -X PUT "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/<record-id>" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data "{\"type\":\"A\",\"name\":\"@\",\"content\":\"$GCLOUD_IP\",\"proxied\":true}"

# Or manually in Cloudflare Dashboard:
# analytics.diegonmarcos.com → $GCLOUD_IP
# sync.diegonmarcos.com → $GCLOUD_IP
# n8n.diegonmarcos.com → $GCLOUD_IP
# git.diegonmarcos.com → $GCLOUD_IP
# cloud.diegonmarcos.com → $GCLOUD_IP
# mail.diegonmarcos.com → $GCLOUD_IP (or direct to Oracle Web 1 for MX)
```

### 4.2 Mail DNS Records

```bash
# Add MX record
# Type: MX
# Name: @
# Mail server: mail.diegonmarcos.com
# Priority: 10

# Add SPF record
# Type: TXT
# Name: @
# Content: "v=spf1 mx a ~all"

# Add DMARC record
# Type: TXT
# Name: _dmarc
# Content: "v=DMARC1; p=quarantine; rua=mailto:postmaster@diegonmarcos.com"
```

---

## Phase 5: Setup Idle Monitor (Auto-Stop)

### 5.1 Install Idle Monitor on Dev Server

```bash
# SSH into dev server
ssh ubuntu@$DEV_SERVER_IP

# Create idle check script
sudo tee /usr/local/bin/idle-check.sh << 'EOF'
#!/bin/bash

IDLE_THRESHOLD=1800  # 30 minutes in seconds
MARKER_FILE="/tmp/last_activity"

# Check for recent Docker activity
DOCKER_ACTIVITY=$(docker stats --no-stream --format "{{.NetIO}}" 2>/dev/null | grep -v "0B / 0B" | wc -l)

# Check for recent SSH connections
SSH_CONNECTIONS=$(who | wc -l)

# Check for recent HTTP requests (if nginx/npm logs exist)
if [ -f /var/log/nginx/access.log ]; then
    RECENT_REQUESTS=$(find /var/log/nginx/access.log -mmin -30 2>/dev/null | wc -l)
else
    RECENT_REQUESTS=0
fi

# If any activity, update marker
if [ $DOCKER_ACTIVITY -gt 0 ] || [ $SSH_CONNECTIONS -gt 0 ] || [ $RECENT_REQUESTS -gt 0 ]; then
    touch $MARKER_FILE
    exit 0
fi

# Check if marker is older than threshold
if [ -f $MARKER_FILE ]; then
    LAST_ACTIVITY=$(stat -c %Y $MARKER_FILE)
    CURRENT_TIME=$(date +%s)
    IDLE_TIME=$((CURRENT_TIME - LAST_ACTIVITY))

    if [ $IDLE_TIME -gt $IDLE_THRESHOLD ]; then
        logger "Idle timeout reached ($IDLE_TIME seconds). Shutting down."
        /sbin/shutdown now
    fi
else
    # First run, create marker
    touch $MARKER_FILE
fi
EOF

sudo chmod +x /usr/local/bin/idle-check.sh

# Add cron job (every 5 minutes)
(crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/idle-check.sh") | crontab -

# Verify cron
crontab -l

# Exit
exit
```

---

## Phase 6: Verification & Testing

### 6.1 Test GCloud NPM

```bash
# Test HTTP
curl -I http://$GCLOUD_IP

# Test NPM admin
curl -I http://$GCLOUD_IP:81

# Test proxy to Matomo
curl -I https://analytics.diegonmarcos.com
```

### 6.2 Test Wake-on-Demand API

```bash
# Start Flask API locally or on server
cd /home/diego/Documents/Git/back-System/cloud/0.spec
python3 cloud_dash.py serve &

# Test status endpoint
curl http://localhost:5000/api/wake/status | python3 -m json.tool

# Test wake endpoint (if VM is stopped)
curl -X POST http://localhost:5000/api/wake/trigger | python3 -m json.tool
```

### 6.3 Full Wake Cycle Test

```bash
# 1. Ensure VM is stopped
oci compute instance action --instance-id $DEV_INSTANCE_ID --action STOP --wait-for-state STOPPED

# 2. Call wake API
curl -X POST http://localhost:5000/api/wake/trigger

# 3. Poll status until RUNNING
while true; do
  STATE=$(oci compute instance get --instance-id $DEV_INSTANCE_ID --query 'data."lifecycle-state"' --raw-output)
  echo "State: $STATE"
  if [ "$STATE" = "RUNNING" ]; then
    echo "VM is now running!"
    break
  fi
  sleep 5
done

# 4. Test services are accessible
curl -I https://n8n.diegonmarcos.com
curl -I https://sync.diegonmarcos.com
```

### 6.4 Test Idle Auto-Stop

```bash
# SSH into dev server and wait 30+ minutes with no activity
# Check syslog for shutdown message
ssh ubuntu@$DEV_SERVER_IP "sudo journalctl -f" &

# Wait and observe... after 30 min idle, should see shutdown
```

---

## Checklist

### Phase 1: GCloud NPM
- [ ] Create arch-1 VM (e2-micro)
- [ ] Configure firewall rules (80, 443, 81)
- [ ] Get external IP
- [ ] SSH and install Docker
- [ ] Deploy NPM container
- [ ] Access NPM admin panel
- [ ] Configure proxy hosts for all domains

### Phase 2: Oracle Dev Server
- [ ] Get compartment/subnet/image OCIDs
- [ ] Create E4.Flex instance (1 OCPU + 8GB)
- [ ] Get instance OCID and IP
- [ ] Update cloud_dash.json with real OCID
- [ ] Configure security list ports
- [ ] SSH and install Docker
- [ ] Deploy all 8 services
- [ ] Test wake/stop cycle

### Phase 3: Migrate Oracle VMs
- [ ] Oracle Web 1: Remove old services
- [ ] Oracle Web 1: Install mail server
- [ ] Oracle Services 1: Remove NPM (keep Matomo)

### Phase 4: DNS
- [ ] Update A records to GCloud IP
- [ ] Add MX record for mail
- [ ] Add SPF/DMARC records

### Phase 5: Idle Monitor
- [ ] Create idle-check.sh script
- [ ] Add cron job
- [ ] Test auto-shutdown

### Phase 6: Verification
- [ ] Test GCloud NPM proxy
- [ ] Test wake API endpoints
- [ ] Test full wake cycle
- [ ] Test idle auto-stop
- [ ] Test all services accessible

---

## Rollback Plan

If deployment fails:

### GCloud Issues
```bash
# Delete VM and start over
gcloud compute instances delete arch-1 --zone=us-central1-a
```

### Oracle Dev Server Issues
```bash
# Terminate instance
oci compute instance terminate --instance-id $DEV_INSTANCE_ID --force
```

### DNS Issues
```bash
# Revert to old Oracle Web 1 IP for all domains
# In Cloudflare: Point all records back to 130.110.251.193
```

---

## Cost Monitoring

```bash
# Check OCI cost
oci account get-subscription --subscription-id <sub-id>

# Monitor dev server hours
oci monitoring metric-data summarize-metrics-data \
  --compartment-id $COMPARTMENT_ID \
  --namespace oci_computeagent \
  --query-text "CpuUtilization[1h].mean()"
```

---

## Commit Message Template

```
feat(infra): deploy architecture v2 to production

GCloud:
- Created arch-1 VM (e2-micro free tier)
- Deployed NPM as central reverse proxy
- Configured firewall rules

Oracle:
- Created oracle-dev-server (E4.Flex 1OCPU+8GB)
- Migrated 8 dev services to dormant VM
- Configured wake-on-demand with idle auto-stop
- Updated Oracle Web 1 for mail only
- Removed NPM from Oracle Services 1

DNS:
- Updated all A records to GCloud NPM
- Added mail MX/SPF/DMARC records

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
```
