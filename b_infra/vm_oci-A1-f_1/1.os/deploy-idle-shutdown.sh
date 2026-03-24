#!/bin/bash
# deploy-idle-shutdown.sh - Deploy idle + daily shutdown to oci-p-flex_1
# Run from local machine: ./deploy-idle-shutdown.sh

set -euo pipefail

VM_IP="144.24.196.72"
VM_USER="ubuntu"
SSH_KEY="/home/diego/git/vault/A0_keys/ssh/id_rsa"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Deploying Idle + Daily Shutdown to oci-p-flex_1 ==="

# Copy files to VM
echo "Copying files to VM..."
scp -i "$SSH_KEY" \
    "$SCRIPT_DIR/idle-shutdown.sh" \
    "$SCRIPT_DIR/idle-shutdown.service" \
    "$SCRIPT_DIR/idle-shutdown.timer" \
    "$SCRIPT_DIR/daily-shutdown.sh" \
    "$SCRIPT_DIR/daily-shutdown.service" \
    "$SCRIPT_DIR/daily-shutdown.timer" \
    "${VM_USER}@${VM_IP}:/tmp/"

# Install on VM
echo "Installing on VM..."
ssh -i "$SSH_KEY" "${VM_USER}@${VM_IP}" 'bash -s' << 'REMOTE_SCRIPT'
set -euo pipefail

echo "Creating directories..."
sudo mkdir -p /opt/scripts
sudo mkdir -p /var/log

echo "Installing scripts..."
sudo mv /tmp/idle-shutdown.sh /opt/scripts/
sudo mv /tmp/daily-shutdown.sh /opt/scripts/
sudo chmod +x /opt/scripts/idle-shutdown.sh
sudo chmod +x /opt/scripts/daily-shutdown.sh

echo "Installing systemd units..."
sudo mv /tmp/idle-shutdown.service /etc/systemd/system/
sudo mv /tmp/idle-shutdown.timer /etc/systemd/system/
sudo mv /tmp/daily-shutdown.service /etc/systemd/system/
sudo mv /tmp/daily-shutdown.timer /etc/systemd/system/

echo "Reloading systemd..."
sudo systemctl daemon-reload

echo "Enabling and starting idle shutdown timer..."
sudo systemctl enable idle-shutdown.timer
sudo systemctl restart idle-shutdown.timer

echo "Enabling and starting daily shutdown timer..."
sudo systemctl enable daily-shutdown.timer
sudo systemctl start daily-shutdown.timer

echo "Creating log file..."
sudo touch /var/log/idle-shutdown.log
sudo chmod 644 /var/log/idle-shutdown.log

echo ""
echo "Verifying installation..."
systemctl list-timers idle-shutdown.timer daily-shutdown.timer --no-pager

echo ""
echo "=== Installation complete ==="
echo "Idle: check every 5 min, shutdown after 30 min idle"
echo "Daily: forced shutdown at 1:00 AM Berlin"
echo "Log: /var/log/idle-shutdown.log"
REMOTE_SCRIPT

echo ""
echo "=== Deployment complete ==="
