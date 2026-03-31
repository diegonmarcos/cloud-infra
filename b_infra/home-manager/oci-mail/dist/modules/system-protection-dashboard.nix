# System Protection — Dashboard
#
# Web-accessible tmux monitoring dashboard served by ttyd.
# Two tabs: "monitoring" (btop + docker stats + journal) and "processes" (btop + htop).
# Accessed via Caddy: https://app.diegonmarcos.com/dash-<vmName>/
#
# Deploys:
#   - /opt/scripts/dashboard-tmux.sh (tmux layout creator)
#   - /etc/systemd/system/dashboard-ttyd.service (ttyd web terminal)
{ vmName }:
{ config, pkgs, lib, ... }:

let
  ttydPort = 7681;
  basePath = "/dash-${vmName}";
  ttydBin = "${pkgs.ttyd}/bin/ttyd";
  tmuxBin = "${pkgs.tmux}/bin/tmux";
  btopBin = "${pkgs.btop}/bin/btop";
  htopBin = "${pkgs.htop}/bin/htop";
  dockerBin = "/usr/bin/docker";
  journalctlBin = "/usr/bin/journalctl";

  dashboardScript = pkgs.writeShellScript "dashboard-tmux.sh" ''
    #!/bin/bash
    set -euo pipefail
    SESSION="dashboard"
    TMUX="${tmuxBin}"

    # Attach to existing session if available
    if "$TMUX" has-session -t "$SESSION" 2>/dev/null; then
      exec "$TMUX" attach-session -t "$SESSION"
    fi

    # ── Tab 1: monitoring (4 panes) ──
    # Top-left: btop
    "$TMUX" new-session -d -s "$SESSION" -n "monitoring" "${btopBin}"

    # Top-right: journal errors
    "$TMUX" split-window -h -t "$SESSION:monitoring" "${journalctlBin} -p err -f --no-hostname -n 100"

    # Bottom-right: journal all
    "$TMUX" split-window -v -t "$SESSION:monitoring.1" "${journalctlBin} -f --no-hostname -n 50"

    # Bottom-left: docker stats (loop with no-stream for compatibility)
    "$TMUX" select-pane -t "$SESSION:monitoring.0"
    "$TMUX" split-window -v -t "$SESSION:monitoring.0" "bash -c 'while true; do ${dockerBin} stats --no-stream --format \"table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\" 2>/dev/null || echo \"docker not running\"; sleep 3; done'"

    # ── Tab 2: processes (2 panes) ──
    "$TMUX" new-window -t "$SESSION" -n "processes" "${btopBin}"
    "$TMUX" split-window -h -t "$SESSION:processes" "${htopBin}"

    # Select tab 1, attach
    "$TMUX" select-window -t "$SESSION:monitoring"
    exec "$TMUX" attach-session -t "$SESSION"
  '';

  serviceUnit = ''
    [Unit]
    Description=ttyd dashboard — web terminal serving tmux monitoring (${vmName})
    After=network.target
    Wants=network.target

    [Service]
    Type=simple
    ExecStartPre=-${tmuxBin} kill-session -t dashboard
    ExecStart=${ttydBin} \
      --port ${toString ttydPort} \
      --base-path ${basePath} \
      --writable \
      --max-clients 3 \
      --ping-interval 30 \
      ${dashboardScript}
    Restart=always
    RestartSec=5
    MemoryMax=64M
    CPUQuota=10%

    [Install]
    WantedBy=multi-user.target
  '';

in {
  home.file.".local/share/system-protection/dashboard-tmux.sh" = {
    executable = true;
    source = dashboardScript;
  };

  home.file.".local/share/system-protection/dashboard-ttyd.service".text = serviceUnit;

  home.activation.installDashboard = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    (
    trap 'echo "[dashboard] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
    LOG="[dashboard]"

    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    if [ -z "$SUDO" ]; then
      echo "$LOG WARN: sudo not found — skipping"
      exit 0
    fi

    SRC="$HOME/.local/share/system-protection"

    # Deploy script
    $SUDO mkdir -p /opt/scripts
    $SUDO cp -f "$SRC/dashboard-tmux.sh" /opt/scripts/dashboard-tmux.sh
    $SUDO chmod +x /opt/scripts/dashboard-tmux.sh

    # Deploy systemd unit (idempotent)
    UNIT_FILE="/etc/systemd/system/dashboard-ttyd.service"
    NEW_UNIT="$(cat "$SRC/dashboard-ttyd.service")"
    CURRENT=""
    [ -f "$UNIT_FILE" ] && CURRENT="$($SUDO cat "$UNIT_FILE" 2>/dev/null || true)"

    if [ "$NEW_UNIT" != "$CURRENT" ]; then
      echo "$NEW_UNIT" | $SUDO tee "$UNIT_FILE" > /dev/null
      $SUDO systemctl daemon-reload
      echo "$LOG updated systemd unit"
    fi

    $SUDO systemctl enable dashboard-ttyd.service 2>/dev/null || true
    if $SUDO systemctl is-active dashboard-ttyd >/dev/null 2>&1; then
      $SUDO systemctl restart dashboard-ttyd
      echo "$LOG restarted"
    else
      $SUDO systemctl start dashboard-ttyd 2>/dev/null || true
      echo "$LOG started"
    fi
    echo "$LOG ttyd dashboard on port ${toString ttydPort} (base-path: ${basePath})"
    ) || echo "[dashboard] FAILED — activation continues"
  '';
}
