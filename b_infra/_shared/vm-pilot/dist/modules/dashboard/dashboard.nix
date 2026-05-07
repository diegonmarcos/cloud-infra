# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : src/modules/dashboard/dashboard.nix
# ║   Engine : b_infra/_shared/vm-pilot/build.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# System Protection — Dashboard
#
# Two services:
#   - HTML dashboard on port 7680 (busybox httpd, sidebar + ttyd iframe)
#     Also serves /health/ and /pilot/data/ via symlinks (no separate httpd)
#   - ttyd web terminal on port 7681 (tmux monitoring, iframe target)
#
# HTML files sourced from vm-pilot/src/html/
# Accessed via Caddy: https://<vm>.app/
{ vmName }:
{ config, pkgs, lib, ... }:

let
  dashboardPort = 7680;
  ttydPort = 7681;
  ttydBin = "${pkgs.ttyd}/bin/ttyd";
  tmuxBin = "${pkgs.tmux}/bin/tmux";
  btopBin = "${pkgs.btop}/bin/btop";
  htopBin = "${pkgs.htop}/bin/htop";
  dockerBin = "${pkgs.docker-client}/bin/docker";
  journalctlBin = "/usr/bin/journalctl";

  dashboardScript = pkgs.writeShellScript "dashboard-tmux.sh" ''
    #!/bin/bash
    set -euo pipefail
    SESSION="dashboard"
    TMUX="${tmuxBin}"

    if "$TMUX" has-session -t "$SESSION" 2>/dev/null; then
      exec "$TMUX" attach-session -t "$SESSION"
    fi

    # Tab 1: monitoring (4 panes)
    "$TMUX" new-session -d -s "$SESSION" -n "monitoring" "${btopBin}"
    "$TMUX" split-window -h -t "$SESSION:monitoring" "${journalctlBin} -p err -f --no-hostname -n 100"
    "$TMUX" split-window -v -t "$SESSION:monitoring.1" "${journalctlBin} -f --no-hostname -n 50"
    "$TMUX" select-pane -t "$SESSION:monitoring.0"
    "$TMUX" split-window -v -t "$SESSION:monitoring.0" "bash -c 'while true; do ${dockerBin} stats --no-stream --format \"table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\" 2>/dev/null || echo \"docker not running\"; sleep 3; done'"

    # Tab 2: processes
    "$TMUX" new-window -t "$SESSION" -n "processes" "${btopBin}"
    "$TMUX" split-window -h -t "$SESSION:processes" "${htopBin}"

    "$TMUX" select-window -t "$SESSION:monitoring"
    exec "$TMUX" attach-session -t "$SESSION"
  '';

in {
  # ── HTML dashboard files ───────────────────────────────────────────
  home.file.".local/share/vm-pilot/html/index.html".source = ../html/index.html;
  home.file.".local/share/vm-pilot/html/style.css".source = ../html/style.css;
  home.file.".local/share/vm-pilot/html/pilot.js".source = ../html/pilot.js;

  # ── tmux script ────────────────────────────────────────────────────
  home.file.".local/share/system-protection/dashboard-tmux.sh" = {
    executable = true;
    source = dashboardScript;
  };

  # ── ttyd service (port 7681, iframe target) ────────────────────────
  home.file.".local/share/system-protection/dashboard-ttyd.service".text = ''
    [Unit]
    Description=ttyd terminal — tmux monitoring (${vmName})
    After=network.target

    [Service]
    Type=simple
    ExecStartPre=-${tmuxBin} kill-session -t dashboard
    ExecStart=${ttydBin} \
      --port ${toString ttydPort} \
      --interface 0.0.0.0 \
      --writable \
      --max-clients 3 \
      --ping-interval 30 \
      --base-path /ttyd \
      ${dashboardScript}
    Restart=always
    RestartSec=5
    MemoryMax=64M
    CPUQuota=10%

    [Install]
    WantedBy=multi-user.target
  '';

  # ── HTML dashboard service (port 7680) ─────────────────────────────
  home.file.".local/share/vm-pilot/dashboard-httpd.service".text = ''
    [Unit]
    Description=vm-pilot dashboard (busybox httpd :${toString dashboardPort})
    After=network.target

    [Service]
    Type=simple
    ExecStartPre=/bin/mkdir -p /opt/pilot/html
    ExecStart=${pkgs.busybox}/bin/busybox httpd -f -p ${toString dashboardPort} -h /opt/pilot/html
    Restart=always
    RestartSec=5
    MemoryMax=8M

    [Install]
    WantedBy=multi-user.target
  '';

  # ── Activation ─────────────────────────────────────────────────────
  home.activation.installDashboard = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    (
    trap 'echo "[dashboard] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR

    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && echo "[dashboard] no sudo — skipping" && exit 0

    SRC_SP="$HOME/.local/share/system-protection"
    SRC_VP="$HOME/.local/share/vm-pilot"

    # Deploy tmux script
    $SUDO mkdir -p /opt/scripts /opt/pilot/html
    $SUDO cp -f "$SRC_SP/dashboard-tmux.sh" /opt/scripts/dashboard-tmux.sh
    $SUDO chmod +x /opt/scripts/dashboard-tmux.sh

    # Deploy HTML
    $SUDO cp -f "$SRC_VP/html/index.html" /opt/pilot/html/index.html
    $SUDO cp -f "$SRC_VP/html/style.css" /opt/pilot/html/style.css
    $SUDO cp -f "$SRC_VP/html/pilot.js" /opt/pilot/html/pilot.js

    # Symlink data dirs into HTML root — single httpd serves everything
    $SUDO mkdir -p /opt/health /opt/pilot/data /opt/pilot/html/pilot
    $SUDO ln -sfn /opt/health /opt/pilot/html/health
    $SUDO ln -sfn /opt/pilot/data /opt/pilot/html/pilot/data

    # Deploy systemd units
    $SUDO cp -f "$SRC_SP/dashboard-ttyd.service" /etc/systemd/system/dashboard-ttyd.service
    $SUDO cp -f "$SRC_VP/dashboard-httpd.service" /etc/systemd/system/dashboard-httpd.service
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable dashboard-ttyd.service dashboard-httpd.service 2>/dev/null || true
    $SUDO systemctl restart dashboard-ttyd.service 2>/dev/null || true
    $SUDO systemctl restart dashboard-httpd.service 2>/dev/null || true

    echo "[dashboard] deployed: html=:${toString dashboardPort} ttyd=:${toString ttydPort} (${vmName}.app)"
    ) || echo "[dashboard] FAILED — activation continues"
  '';
}
