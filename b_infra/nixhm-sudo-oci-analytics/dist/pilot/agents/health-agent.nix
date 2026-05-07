# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : b_infra/nixhm-sudo-oci-analytics/src/pilot/agents/health-agent.nix
# ║   Engine : 1_workflows/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Health Agent — collect VM state to /opt/health/latest.json
# Runs every 5 min. Served via dashboard-httpd symlink (no standalone httpd).
#
# Split from: system-protection-watchdog-petter-dropbear-health-agent.nix
# Imported by: default.nix
#
{ config, pkgs, lib, ... }:
{
  home.file.".local/share/system-protection/health-agent.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      set -euo pipefail
      VM=$(hostname -s 2>/dev/null || echo "unknown")
      OUT="/opt/health/latest.json"
      mkdir -p /opt/health

      # Collect data
      MEM=$(free -m 2>/dev/null | awk '/Mem/{printf "{\"used\":%d,\"total\":%d,\"pct\":%d}", $3, $2, ($2>0 ? $3*100/$2 : 0)}' || echo '{"used":0,"total":0,"pct":0}')
      SWAP=$(free -m 2>/dev/null | awk '/Swap/{printf "{\"used\":%d,\"total\":%d}", $3, $2}' || echo '{"used":0,"total":0}')
      DISK=$(df -h / 2>/dev/null | awk 'NR==2{printf "{\"used\":\"%s\",\"total\":\"%s\",\"pct\":\"%s\"}", $3, $2, $5}' || echo '{"used":"?","total":"?","pct":"?"}')
      LOAD=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo "0 0 0")
      UPTIME=$(awk '{printf "%dd %dh", $1/86400, ($1%86400)/3600}' /proc/uptime 2>/dev/null || echo "?")
      WG_UP=$(ip link show wg0 >/dev/null 2>&1 && echo "true" || echo "false")

      # Docker containers via awk (POSIX, no subshell issues)
      TMPF=$(mktemp)
      docker ps -a --format '{{.Names}}|{{.Status}}' > "$TMPF" 2>/dev/null || true
      CTR_TOTAL=$(wc -l < "$TMPF" 2>/dev/null); CTR_TOTAL=''${CTR_TOTAL:-0}
      CTR_RUNNING=$(docker ps --format '{{.Names}}' 2>/dev/null | wc -l); CTR_RUNNING=''${CTR_RUNNING:-0}
      CONTAINERS=$(awk -F'|' '
        BEGIN { printf "[" }
        NR > 1 { printf "," }
        {
          h = "none"
          if ($2 ~ /\(healthy\)/) h = "healthy"
          else if ($2 ~ /\(unhealthy\)/) h = "unhealthy"
          else if ($2 ~ /health: starting/) h = "starting"
          else if ($2 ~ /^Created/) h = "created"
          else if ($2 ~ /^Exited/) h = "exited"
          gsub(/"/, "\\\"", $2)
          printf "{\"name\":\"%s\",\"status\":\"%s\",\"health\":\"%s\"}", $1, $2, h
        }
        END { printf "]" }
      ' "$TMPF" 2>/dev/null || echo "[]")
      rm -f "$TMPF"

      # Write JSON
      cat > "$OUT" <<EOF
      {
        "vm": "$VM",
        "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
        "mem": $MEM,
        "swap": $SWAP,
        "disk": $DISK,
        "load": "$LOAD",
        "uptime": "$UPTIME",
        "wg_up": $WG_UP,
        "containers_running": $CTR_RUNNING,
        "containers_total": $CTR_TOTAL,
        "containers": $CONTAINERS
      }
      EOF
      echo "[health-agent] Updated $OUT"
    '';
  };

  home.file.".local/share/system-protection/health-agent.service".text = ''
    [Unit]
    Description=Health Agent — collect VM state to /opt/health/latest.json
    After=network.target docker.service
    [Service]
    Type=oneshot
    ExecStart=/opt/scripts/health-agent.sh
    User=root
    TimeoutStartSec=30
    [Install]
    WantedBy=multi-user.target
  '';

  home.file.".local/share/system-protection/health-agent.timer".text = ''
    [Unit]
    Description=Health Agent timer (every 5 min)
    [Timer]
    OnBootSec=1min
    OnUnitActiveSec=5min
    RandomizedDelaySec=15s
    [Install]
    WantedBy=timers.target
  '';

  # ── Activation ────────────────────────────────────────────────────────
  home.activation.installHealthAgent = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    trap 'echo "[health-agent] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && echo "[health-agent] no sudo — skipping" && exit 0

    SRC="$HOME/.local/share/system-protection"

    $SUDO mkdir -p /opt/scripts /opt/health
    $SUDO cp -f "$SRC/health-agent.sh" /opt/scripts/health-agent.sh
    $SUDO chmod +x /opt/scripts/health-agent.sh
    $SUDO cp -f "$SRC/health-agent.service" /etc/systemd/system/health-agent.service
    $SUDO cp -f "$SRC/health-agent.timer" /etc/systemd/system/health-agent.timer

    # Remove legacy standalone httpd (now served via dashboard-httpd symlinks)
    if $SUDO systemctl is-active health-httpd >/dev/null 2>&1; then
      $SUDO systemctl stop health-httpd 2>/dev/null || true
      $SUDO systemctl disable health-httpd 2>/dev/null || true
    fi
    $SUDO rm -f /etc/systemd/system/health-httpd.service

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable health-agent.timer 2>/dev/null || true
    $SUDO systemctl start health-agent.timer 2>/dev/null || true
    $SUDO systemctl start health-agent.service 2>/dev/null || true

    echo "[health-agent] deployed: timer=5min (served via dashboard-httpd)"
    ) || echo "[health-agent] FAILED — activation continues"
  '';
}
