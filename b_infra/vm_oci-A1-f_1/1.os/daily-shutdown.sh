#!/bin/bash
# daily-shutdown.sh - Force shutdown at 1:00 AM Berlin time
# Location on VM: /opt/scripts/daily-shutdown.sh

set -euo pipefail

LOG_FILE="/var/log/idle-shutdown.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log "=== DAILY SHUTDOWN (1:00 AM Berlin) ==="

# Stop Docker containers gracefully
log "Stopping Docker containers..."
docker stop $(docker ps -q) 2>/dev/null || true

log "Syncing filesystems..."
sync

log "Shutting down NOW"
/sbin/shutdown -h now "Daily scheduled shutdown (1:00 AM Berlin)"
