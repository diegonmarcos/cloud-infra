#!/bin/bash
# idle-shutdown.sh - Auto-shutdown VM after 4 hours of inactivity
# Location on VM: /opt/scripts/idle-shutdown.sh
#
# VM profile: OCI E4.Flex - 1 OCPU (ARM), 8GB RAM
# Always-on containers: nocodb-db (~1% CPU), photoprism_rclone (~0% CPU)
#
# Idle conditions (ALL must be true):
#   - No active SSH sessions
#   - CPU load < 60% (1 core, background containers ~5-10% baseline)
#   - No container using > 30% CPU (excludes background DB idle)
#   - Network < 50KB/s
#   - No active Syncthing transfers
#   - No active n8n workflow executions
#
# The script tracks idle time in a state file. When idle time exceeds
# IDLE_TIMEOUT_SECONDS, the VM is shut down via OCI CLI or systemd.

set -euo pipefail

# === Configuration ===
IDLE_TIMEOUT_SECONDS=14400  # 4 hours
STATE_FILE="/var/run/idle-shutdown-state"
LOG_FILE="/var/log/idle-shutdown.log"
CPU_THRESHOLD=60           # Percent - load avg * 100 / nproc (1 core baseline ~5-10%)
DOCKER_CPU_THRESHOLD=30    # Per-container CPU % to consider active
NETWORK_THRESHOLD=51200    # 50KB/s - lower than before (VM baseline ~500 B/s)
MIN_UPTIME_SECONDS=600     # Don't shutdown within 10 min of boot (containers need startup time)

# === Logging ===
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# === Activity Checks ===

check_ssh_sessions() {
    # Count SSH sessions
    local ssh_count
    ssh_count=$(who 2>/dev/null | grep -c pts || true)
    ssh_count=${ssh_count:-0}

    if [[ "$ssh_count" -gt 0 ]]; then
        log "ACTIVE: $ssh_count SSH session(s) detected"
        return 1  # Not idle
    fi
    return 0  # Idle
}

check_cpu_usage() {
    # Get 1-minute load average and compare to threshold
    local cpu_usage
    cpu_usage=$(awk '{printf "%.0f", $1 * 100 / '"$(nproc)"'}' /proc/loadavg)

    if [[ "$cpu_usage" -ge "$CPU_THRESHOLD" ]]; then
        log "ACTIVE: CPU usage at ${cpu_usage}% (threshold: ${CPU_THRESHOLD}%)"
        return 1  # Not idle
    fi
    return 0  # Idle
}

check_syncthing() {
    # Check if Syncthing has active transfers via API (port 8384)
    if ! curl -s --max-time 5 "http://localhost:8384/rest/system/connections" >/dev/null 2>&1; then
        # Syncthing not running or not responding - consider idle
        return 0
    fi

    # Check for active downloads/uploads using completion API
    local sync_status completion
    sync_status=$(curl -s --max-time 5 "http://localhost:8384/rest/db/completion" 2>/dev/null) || sync_status='{"completion":100}'

    # Extract completion percentage (use sed for compatibility)
    completion=$(echo "$sync_status" | sed -n 's/.*"completion":\s*\([0-9.]*\).*/\1/p' | head -1)
    completion=${completion:-100}
    completion=${completion%.*}  # Remove decimals

    if [[ "$completion" -lt 100 ]]; then
        log "ACTIVE: Syncthing transfer in progress (${completion}% complete)"
        return 1  # Not idle
    fi
    return 0  # Idle
}

check_n8n() {
    # Check if n8n has running executions (port 5678)
    if ! curl -s --max-time 5 "http://localhost:5678/healthz" >/dev/null 2>&1; then
        # n8n not running - consider idle
        return 0
    fi

    # Check if n8n container is actively using CPU
    local n8n_cpu
    n8n_cpu=$(docker stats --no-stream --format "{{.CPUPerc}}" n8n 2>/dev/null | tr -d '%') || n8n_cpu="0"
    n8n_cpu=${n8n_cpu:-0}
    n8n_cpu=${n8n_cpu%.*}  # Remove decimals

    if [[ "$n8n_cpu" -ge 5 ]]; then
        log "ACTIVE: n8n using ${n8n_cpu}% CPU"
        return 1  # Not idle
    fi
    return 0  # Idle
}

check_docker_activity() {
    # Check if any container is using significant CPU (above threshold)
    local active_containers active_names
    active_names=$(docker stats --no-stream --format "{{.Name}}:{{.CPUPerc}}" 2>/dev/null | \
        awk -F: '{gsub(/%/,"",$2); if($2 > '"$DOCKER_CPU_THRESHOLD"') print $1}') || active_names=""

    active_containers=$(echo "$active_names" | grep -c . || true)
    active_containers=${active_containers:-0}

    if [[ "$active_containers" -gt 0 ]]; then
        log "ACTIVE: $active_containers container(s) using >${DOCKER_CPU_THRESHOLD}% CPU: $active_names"
        return 1  # Not idle
    fi
    return 0  # Idle
}

check_network_activity() {
    # Check network throughput over 2 seconds
    # Find the primary network interface (not lo)
    local iface
    iface=$(ip route | grep default | awk '{print $5}' | head -1)

    if [[ -z "$iface" ]]; then
        # No default route, assume idle
        return 0
    fi

    local rx1 tx1 rx2 tx2
    rx1=$(cat "/sys/class/net/${iface}/statistics/rx_bytes" 2>/dev/null || echo 0)
    tx1=$(cat "/sys/class/net/${iface}/statistics/tx_bytes" 2>/dev/null || echo 0)

    sleep 2

    rx2=$(cat "/sys/class/net/${iface}/statistics/rx_bytes" 2>/dev/null || echo 0)
    tx2=$(cat "/sys/class/net/${iface}/statistics/tx_bytes" 2>/dev/null || echo 0)

    local rx_rate tx_rate
    rx_rate=$(( (rx2 - rx1) / 2 ))  # bytes per second
    tx_rate=$(( (tx2 - tx1) / 2 ))

    # Threshold: 50KB/s (VM baseline is ~500 B/s)
    if [[ "$rx_rate" -gt "$NETWORK_THRESHOLD" ]] || [[ "$tx_rate" -gt "$NETWORK_THRESHOLD" ]]; then
        log "ACTIVE: Network activity RX:${rx_rate}B/s TX:${tx_rate}B/s"
        return 1  # Not idle
    fi
    return 0  # Idle
}

# === State Management ===

get_idle_start() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo "0"
    fi
}

set_idle_start() {
    echo "$1" > "$STATE_FILE"
}

reset_idle_timer() {
    set_idle_start "0"
    log "Idle timer reset - activity detected"
}

# === Main Logic ===

is_system_idle() {
    # All checks must pass for system to be considered idle
    check_ssh_sessions || return 1
    check_cpu_usage || return 1
    check_docker_activity || return 1
    check_network_activity || return 1
    check_syncthing || return 1
    check_n8n || return 1

    return 0  # All checks passed - system is idle
}

check_uptime() {
    local uptime_seconds
    uptime_seconds=$(awk '{print int($1)}' /proc/uptime)

    if [[ "$uptime_seconds" -lt "$MIN_UPTIME_SECONDS" ]]; then
        log "System just booted (${uptime_seconds}s ago), skipping shutdown check"
        return 1
    fi
    return 0
}

perform_shutdown() {
    log "=== INITIATING SHUTDOWN ==="
    log "System has been idle for $IDLE_TIMEOUT_SECONDS seconds"

    # Send notification (optional - could integrate with n8n webhook)
    # curl -X POST "https://n8n.diegonmarcos.com/webhook/vm-shutdown" -d '{"vm":"oci-p-flex_1"}' || true

    # Clean shutdown
    log "Stopping Docker containers gracefully..."
    docker stop $(docker ps -q) 2>/dev/null || true

    log "Syncing filesystems..."
    sync

    log "Shutting down NOW"
    /sbin/shutdown -h now "Idle timeout reached (${IDLE_TIMEOUT_SECONDS}s)"
}

main() {
    log "=== Idle shutdown check started ==="

    # Ensure we're running as root
    if [[ $EUID -ne 0 ]]; then
        log "ERROR: This script must be run as root"
        exit 1
    fi

    # Check minimum uptime
    if ! check_uptime; then
        exit 0
    fi

    # Check if system is idle
    if is_system_idle; then
        log "System is IDLE"

        local idle_start
        idle_start=$(get_idle_start)
        local now
        now=$(date +%s)

        if [[ "$idle_start" == "0" ]]; then
            # Start tracking idle time
            set_idle_start "$now"
            log "Started idle timer at $now"
        else
            # Check if we've exceeded timeout
            local idle_duration
            idle_duration=$((now - idle_start))
            log "Idle for ${idle_duration}s (timeout: ${IDLE_TIMEOUT_SECONDS}s)"

            if [[ "$idle_duration" -ge "$IDLE_TIMEOUT_SECONDS" ]]; then
                perform_shutdown
            fi
        fi
    else
        # System is active - reset timer
        local current_idle
        current_idle=$(get_idle_start)
        if [[ "$current_idle" != "0" ]]; then
            reset_idle_timer
        fi
    fi

    log "=== Check complete ==="
}

# Run main function
main "$@"
