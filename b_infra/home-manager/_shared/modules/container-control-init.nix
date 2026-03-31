# Container Control Init — owns Docker lifecycle + data-driven sequential startup
#
# Docker is DISABLED from systemd auto-start (system-protection-systemd-control).
# This service is the ONLY way Docker and containers start.
#
# Data-driven: container-init.json provides VM identity + config.
# At boot: clones/pulls cloud-data, detects drift, pulls images, starts containers.
#
# Deploys:
#   - /opt/scripts/container-init.sh (the script)
#   - /opt/scripts/container-init.json (VM identity + config)
#   - /etc/systemd/system/docker.service (nix dockerd path)
#   - /etc/systemd/system/container-init.service
#   - ~/container-init.sh (symlink for easy access)
{ vmName ? "unknown" }:
{ config, pkgs, lib, ... }:

let
  dockerdBin = "${pkgs.docker}/bin/dockerd";
  cloudData = builtins.fromJSON (builtins.readFile ./cloud-data-home-manager.json);
  vmData = cloudData.vms.${vmName} or {};
  containerInitJson = builtins.toJSON {
    vm_alias = vmName;
    vm_id = vmData.instance_id or "";
    cloud_data_repo = "https://github.com/diegonmarcos/cloud-data.git";
    cloud_data_dir = "${vmData.home or "/home/diego"}/git/cloud-data";
    containers_dir = "/opt/containers";
    ntfy_base = cloudData.monitoring.ntfy_base or "https://rss.diegonmarcos.com";
    ntfy_topic = "container-init";
    docker_timeout = 60;
    start_delay = 5;
    pull_nice = 19;
    pull_ionice = 3;
    git_user = vmData.user or "diego";
  };
in {
  # ── Script: standalone .sh file (no nix interpolation) ──────────────
  home.file.".local/share/container-init/container-init.sh".source = ./container-control-init.sh;

  # ── Config JSON: VM identity + settings (auto-generated from cloud-data) ──
  home.file.".local/share/container-init/container-init.json".text = containerInitJson;

  # ── Symlinks in ~/ for easy access ───────────────────────────────────
  home.file."container-init.sh".source = config.lib.file.mkOutOfStoreSymlink "/opt/scripts/container-init.sh";
  home.file."container-init.json".source = config.lib.file.mkOutOfStoreSymlink "/opt/scripts/container-init.json";
  home.file."container-init-drift.json".source = config.lib.file.mkOutOfStoreSymlink "/var/log/container-init-drift.json";
  home.file."container-init-boot.json".source = config.lib.file.mkOutOfStoreSymlink "/var/log/container-init-boot.json";
  home.file."containers".source = config.lib.file.mkOutOfStoreSymlink "/opt/containers";
  home.file."scripts".source = config.lib.file.mkOutOfStoreSymlink "/opt/scripts";

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

  # ── Systemd unit — resource-limited so SSH never hangs ──────────────
  home.file.".local/share/container-init/container-init.service".text = ''
    [Unit]
    Description=Container Init — Docker + data-driven sequential startup
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

    [Install]
    WantedBy=multi-user.target
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

    # Deploy script + config JSON
    $SUDO mkdir -p /opt/scripts
    $SUDO cp -f "$SRC/container-init.sh" /opt/scripts/container-init.sh
    $SUDO cp -f "$SRC/container-init.json" /opt/scripts/container-init.json
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
    $SUDO systemctl enable container-init.service 2>/dev/null || true

    echo "[container-init] deployed: data-driven Docker + sequential startup on boot"
    ) || echo "[container-init] FAILED — see errors above, activation continues"
  '';
}
