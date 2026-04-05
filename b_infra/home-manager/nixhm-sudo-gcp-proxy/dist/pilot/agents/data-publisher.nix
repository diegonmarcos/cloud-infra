# Data publisher — collect containers.json + journal-errors.json every 5 min
# Serves /opt/pilot/data/ on port 8198 via busybox httpd
#
{ config, pkgs, lib, ... }:
{
  home.file.".local/share/vm-pilot/data-publisher.sh" = {
    executable = true;
    source = ../scripts/data-publisher.sh;
  };

  home.file.".local/share/vm-pilot/data-publisher.service".text = ''
    [Unit]
    Description=Data publisher — collect VM data JSONs
    After=network.target docker.service

    [Service]
    Type=oneshot
    ExecStart=/opt/scripts/data-publisher.sh
    User=root
    TimeoutStartSec=30
  '';

  home.file.".local/share/vm-pilot/data-publisher.timer".text = ''
    [Unit]
    Description=Data publisher timer (every 5 min)

    [Timer]
    OnBootSec=2min
    OnUnitActiveSec=5min

    [Install]
    WantedBy=timers.target
  '';

  home.file.".local/share/vm-pilot/data-httpd.service".text = ''
    [Unit]
    Description=Data HTTP server (busybox httpd :8198 → /opt/pilot/data/)
    After=network.target

    [Service]
    Type=simple
    ExecStartPre=/bin/mkdir -p /opt/pilot/data
    ExecStart=${pkgs.busybox}/bin/busybox httpd -f -p 8198 -h /opt/pilot/data
    Restart=always
    RestartSec=5
    User=root

    [Install]
    WantedBy=multi-user.target
  '';

  home.activation.installDataPublisher = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && exit 0

    SRC="$HOME/.local/share/vm-pilot"
    $SUDO mkdir -p /opt/scripts /opt/pilot/data
    $SUDO cp -f "$SRC/data-publisher.sh" /opt/scripts/data-publisher.sh
    $SUDO chmod +x /opt/scripts/data-publisher.sh
    $SUDO cp -f "$SRC/data-publisher.service" /etc/systemd/system/data-publisher.service
    $SUDO cp -f "$SRC/data-publisher.timer" /etc/systemd/system/data-publisher.timer
    $SUDO cp -f "$SRC/data-httpd.service" /etc/systemd/system/data-httpd.service
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable data-publisher.timer data-httpd.service 2>/dev/null || true
    $SUDO systemctl start data-publisher.timer 2>/dev/null || true
    $SUDO systemctl start data-publisher.service 2>/dev/null || true
    $SUDO systemctl restart data-httpd.service 2>/dev/null || true
    echo "[data-publisher] deployed: timer=5min httpd=:8198"
    ) || echo "[data-publisher] FAILED — activation continues"
  '';
}
