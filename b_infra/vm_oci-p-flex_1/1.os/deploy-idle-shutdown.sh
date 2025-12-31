#!/bin/bash
# deploy-idle-shutdown.sh - Deploy idle shutdown to oci-p-flex_1
# Run from local machine: ./deploy-idle-shutdown.sh

set -euo pipefail

VM_IP="84.235.234.87"
VM_USER="ubuntu"
SSH_KEY="/home/diego/Documents/Git/LOCAL_KEYS/00_terminal/ssh/id_rsa"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Deploying Idle Shutdown to oci-p-flex_1 ==="

# Copy files to VM
echo "Copying files to VM..."
scp -i "$SSH_KEY" \
    "$SCRIPT_DIR/idle-shutdown.sh" \
    "$SCRIPT_DIR/idle-shutdown.service" \
    "$SCRIPT_DIR/idle-shutdown.timer" \
    "${VM_USER}@${VM_IP}:/tmp/"

# Install on VM
echo "Installing on VM..."
ssh -i "$SSH_KEY" "${VM_USER}@${VM_IP}" 'bash -s' << 'REMOTE_SCRIPT'
set -euo pipefail

echo "Creating directories..."
sudo mkdir -p /opt/scripts
sudo mkdir -p /var/log

echo "Installing script..."
sudo mv /tmp/idle-shutdown.sh /opt/scripts/
sudo chmod +x /opt/scripts/idle-shutdown.sh

echo "Installing systemd units..."
sudo mv /tmp/idle-shutdown.service /etc/systemd/system/
sudo mv /tmp/idle-shutdown.timer /etc/systemd/system/

echo "Reloading systemd..."
sudo systemctl daemon-reload

echo "Enabling and starting timer..."
sudo systemctl enable idle-shutdown.timer
sudo systemctl start idle-shutdown.timer

echo "Creating log file..."
sudo touch /var/log/idle-shutdown.log
sudo chmod 644 /var/log/idle-shutdown.log

echo "Verifying installation..."
systemctl status idle-shutdown.timer --no-pager || true
systemctl list-timers idle-shutdown.timer --no-pager

echo ""
echo "=== Installation complete ==="
echo "Timer runs every 5 minutes"
echo "Shutdown after 30 minutes idle"
echo "Log: /var/log/idle-shutdown.log"
REMOTE_SCRIPT

echo ""
echo "=== Deployment complete ==="
