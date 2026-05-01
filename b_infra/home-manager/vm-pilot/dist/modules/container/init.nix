# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : src/modules/container/init.nix
# ║   Engine : b_infra/home-manager/vm-pilot/build.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

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
  youkiBin = "${pkgs.youki}/bin/youki";
  # 2026-04-27 migrated: cloud-data-home-manager.json → _cloud-data-consolidated.json[._home_manager.vms + .native.monitoring]
  consolidated = builtins.fromJSON (builtins.readFile ../_cloud-data-consolidated.json);
  cloudData = {
    vms = consolidated._home_manager.vms or {};
    monitoring = consolidated.native.monitoring or {};
  };
  vmData = cloudData.vms.${vmName} or {};
  # Read HM build.json for this VM (delivery method, image, etc.)
  # HM configs live at b_infra/home-manager/nixhm-sudo-<vmName>/build.json
  # From here (vm-pilot/src/modules/container/), that's ../../../../nixhm-sudo-<vmName>/
  hmBuildJsonPath = ../../../../. + "/nixhm-sudo-${vmName}/build.json";
  hmBuildJson = if builtins.pathExists hmBuildJsonPath
    then builtins.fromJSON (builtins.readFile hmBuildJsonPath)
    else {};
  hmConfig = hmBuildJson.hm or {};

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
    # HM self-update config
    hm_delivery = hmConfig.delivery or "nix-copy";
    hm_image = hmConfig.image or "";
    hm_user = hmConfig.user or vmData.user or "diego";
    hm_config = hmConfig.config or "";
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

  # ── Docker daemon.json — youki (Rust) replaces runc (Go) as default runtime ──
  home.file.".local/share/container-init/daemon.json".text = builtins.toJSON {
    default-runtime = "youki";
    runtimes = {
      youki = { path = youkiBin; };
    };
    log-driver = "json-file";
    log-opts = {
      max-size = "10m";
      max-file = "3";
    };
  };

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

  # No systemd service — container-init.sh is run manually or via dtk/cron, not at boot.
  # Docker is also manual-start only. This avoids boot OOM on E2 Micros.

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

    # Deploy daemon.json (youki runtime + log config)
    $SUDO mkdir -p /etc/docker
    DAEMON_JSON="$SRC/daemon.json"
    DAEMON_DEST="/etc/docker/daemon.json"
    DJNEW=$(cat "$DAEMON_JSON")
    DJOLD=$($SUDO cat "$DAEMON_DEST" 2>/dev/null || true)
    if [ "$DJNEW" != "$DJOLD" ]; then
      echo "$DJNEW" | $SUDO tee "$DAEMON_DEST" > /dev/null
      echo "[container-init] daemon.json deployed (youki runtime)"
    fi

    # Deploy docker.service (only if changed)
    DOCKER_UNIT="$SRC/docker.service"
    DOCKER_DEST="/etc/systemd/system/docker.service"
    DNEW=$(cat "$DOCKER_UNIT")
    DOLD=$($SUDO cat "$DOCKER_DEST" 2>/dev/null || true)
    if [ "$DNEW" != "$DOLD" ]; then
      echo "$DNEW" | $SUDO tee "$DOCKER_DEST" > /dev/null
      echo "[container-init] docker.service deployed"
    fi

    # Remove stale container-init.service if it exists (no longer systemd-managed)
    if [ -f /etc/systemd/system/container-init.service ]; then
      $SUDO systemctl disable container-init.service 2>/dev/null || true
      $SUDO rm -f /etc/systemd/system/container-init.service
      echo "[container-init] removed stale systemd service"
    fi

    # Disable docker from systemd auto-start (container-init.sh starts it manually)
    $SUDO systemctl disable docker.service 2>/dev/null || true
    $SUDO systemctl daemon-reload

    echo "[container-init] deployed: script-only (no systemd service, manual start via dtk/cron)"
    ) || echo "[container-init] FAILED — see errors above, activation continues"
  '';
}
