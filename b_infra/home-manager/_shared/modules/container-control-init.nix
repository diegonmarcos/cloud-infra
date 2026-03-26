# Container Control Init — owns Docker lifecycle + sequential container startup
#
# Docker is DISABLED from systemd auto-start (system-protection-systemd-control).
# This service is the ONLY way Docker and containers start.
#
# Script: container-control-init.sh (standalone, no nix interpolation)
# Config: reads cloud-data-home-manager.json at runtime
#
# Deploys:
#   - /opt/scripts/container-init.sh (from container-control-init.sh)
#   - /opt/scripts/cloud-data-home-manager.json (for runtime config)
#   - /etc/systemd/system/docker.service (nix dockerd path)
#   - /etc/docker/daemon.json (iptables + DNS)
#   - /etc/systemd/system/container-init.service
{ config, pkgs, lib, ... }:

let
  cloudData = builtins.fromJSON (builtins.readFile ./cloud-data-home-manager.json);
  dockerdBin = "${pkgs.docker}/bin/dockerd";
in {
  # ── Script: standalone .sh file (no nix interpolation) ──────────────
  home.file.".local/share/container-init/container-init.sh".source = ./container-control-init.sh;

  # ── Cloud-data JSON for runtime config ──────────────────────────────
  home.file.".local/share/container-init/cloud-data-home-manager.json".source = ./cloud-data-home-manager.json;

  # ── Docker unit file — NO [Install], container-init starts it ───────
  home.file.".local/share/container-init/docker.service".text = ''
    [Unit]
    Description=Docker Application Container Engine (nix)
    After=network-online.target

    [Service]
    Type=notify
    ExecStartPre=/bin/bash -c '[ -d /var/run/docker.sock ] && rm -rf /var/run/docker.sock || true'
    ExecStart=${dockerdBin}
    ExecReload=/bin/kill -s HUP $MAINPID
    Restart=always
    RestartSec=5
    LimitNOFILE=infinity
    LimitNPROC=infinity
    LimitCORE=infinity
    CPUQuota=80%
    Delegate=yes
    KillMode=process
  '';

  # ── Docker daemon config — single owner (iptables + DNS) ────────────
  home.file.".local/share/container-init/daemon.json".text = builtins.toJSON {
    iptables = false;
    ip6tables = false;
    dns = [ cloudData.dns.primary cloudData.dns.fallback ];
  };

  # ── Systemd unit — resource-limited so SSH never hangs ──────────────
  home.file.".local/share/container-init/container-init.service".text = ''
    [Unit]
    Description=Container Init — Docker + sequential container startup
    After=network-online.target firewall.service disk-swap.service zram-setup.service
    Wants=network-online.target

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/opt/scripts/container-init.sh
    TimeoutStartSec=900
    StandardOutput=journal+console
    StandardError=journal+console
    CPUQuota=70%
    IOWeight=50
    Nice=10
    OOMScoreAdjust=200

  '';

  # ── Activation: deploy to system locations ──────────────────────────
  home.activation.installContainerInit = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    trap 'echo "[container-init] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    if [ -z "$SUDO" ]; then
      echo "[container-init] WARNING: sudo not found — skipping"
      exit 0
    fi

    SRC="$HOME/.local/share/container-init"

    # Deploy script + cloud-data JSON
    $SUDO mkdir -p /opt/scripts
    $SUDO cp -f "$SRC/container-init.sh" /opt/scripts/container-init.sh
    $SUDO cp -f "$SRC/cloud-data-home-manager.json" /opt/scripts/cloud-data-home-manager.json
    $SUDO chmod +x /opt/scripts/container-init.sh

    # Deploy docker.service (only if changed)
    DOCKER_UNIT="$SRC/docker.service"
    DOCKER_DEST="/etc/systemd/system/docker.service"
    DNEW=$(cat "$DOCKER_UNIT")
    DOLD=$($SUDO cat "$DOCKER_DEST" 2>/dev/null || true)
    if [ "$DNEW" != "$DOLD" ]; then
      echo "$DNEW" | $SUDO tee "$DOCKER_DEST" > /dev/null
      echo "[container-init] docker.service deployed"
    fi

    # Deploy daemon.json (only if changed)
    DAEMON_SRC="$SRC/daemon.json"
    DAEMON_DEST="/etc/docker/daemon.json"
    $SUDO mkdir -p /etc/docker
    DJNEW=$(cat "$DAEMON_SRC")
    DJOLD=$($SUDO cat "$DAEMON_DEST" 2>/dev/null || true)
    if [ "$DJNEW" != "$DJOLD" ]; then
      echo "$DJNEW" | $SUDO tee "$DAEMON_DEST" > /dev/null
      echo "[container-init] daemon.json deployed"
    fi

    # Deploy container-init.service (only if changed)
    UNIT_DEST="/etc/systemd/system/container-init.service"
    NEW_UNIT=$(cat "$SRC/container-init.service")
    CURRENT=$($SUDO cat "$UNIT_DEST" 2>/dev/null || true)
    if [ "$NEW_UNIT" != "$CURRENT" ]; then
      echo "$NEW_UNIT" | $SUDO tee "$UNIT_DEST" > /dev/null
      echo "[container-init] systemd unit deployed"
    fi

    # Disable docker from systemd auto-start
    $SUDO systemctl disable docker.service 2>/dev/null || true
    $SUDO systemctl daemon-reload
    $SUDO systemctl disable container-init.service 2>/dev/null || true

    # Restart sshd to pick up protection drop-ins
    $SUDO systemctl restart sshd 2>/dev/null || $SUDO systemctl restart ssh 2>/dev/null || true

    echo "[container-init] deployed: Docker + sequential startup on boot"
    ) || echo "[container-init] FAILED — see errors above, activation continues"
  '';
}
