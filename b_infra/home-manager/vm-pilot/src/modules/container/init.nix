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
  cloudData = builtins.fromJSON (builtins.readFile ../cloud-data-home-manager.json);
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

  # Boot-time auto-start of Docker + containers.
  # OPT-IN per VM via nixhm-sudo-<vm>/build.json → hm.docker_autostart = true.
  # E2 Micros (1GB) leave it false to avoid boot OOM. A1 Flex (24GB) and
  # similar can safely enable it so a reboot brings the stack back up
  # without manual `dtk container-init`.
  dockerAutostart = hmConfig.docker_autostart or false;
  installSection = if dockerAutostart then ''

    [Install]
    WantedBy=multi-user.target
  '' else "";
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

  # ── Docker unit file ─────────────────────────────────────────────────
  # [Install] section is appended only when hm.docker_autostart is true
  # in the VM's nixhm-sudo-<vm>/build.json. Otherwise Docker stays
  # manual-start (safe for E2 Micros — boot Docker via dtk/container-init
  # only when memory headroom allows).
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
  '' + installSection;

  # ── Container bring-up unit (only when docker_autostart) ─────────────
  # When Docker auto-starts at boot, also auto-bring-up containers in
  # /opt/containers/*/. Runs once per boot, after docker.service is up.
  # No-op when dockerAutostart=false (file not deployed).
  home.file.".local/share/container-init/container-up.service" = lib.mkIf dockerAutostart {
    text = ''
      [Unit]
      Description=Bring up all containers in /opt/containers (post Docker start)
      After=docker.service
      Requires=docker.service
      ConditionPathExists=/opt/scripts/vm-images-pull-up.sh

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/opt/scripts/vm-images-pull-up.sh
      TimeoutStartSec=20m
      StandardOutput=journal
      StandardError=journal

      [Install]
      WantedBy=multi-user.target
    '';
  };

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

    # Boot-time auto-start: parameterized by hm.docker_autostart in
    # nixhm-sudo-<vm>/build.json (rendered into installSection above and
    # gating the container-up.service file existence).
    if [ "${if dockerAutostart then "true" else "false"}" = "true" ]; then
      # Deploy and enable container-up.service (brings containers up after Docker)
      $SUDO cp -f "$SRC/container-up.service" /etc/systemd/system/container-up.service
      # Ensure vm-images-pull-up.sh script lives at /opt/scripts (deploy hook)
      if [ -f "$HOME/.local/share/container-init/vm-images-pull-up.sh" ]; then
        $SUDO cp -f "$HOME/.local/share/container-init/vm-images-pull-up.sh" /opt/scripts/vm-images-pull-up.sh
        $SUDO chmod +x /opt/scripts/vm-images-pull-up.sh
      fi
      $SUDO systemctl daemon-reload
      $SUDO systemctl enable docker.service 2>/dev/null || true
      $SUDO systemctl enable container-up.service 2>/dev/null || true
      echo "[container-init] AUTOSTART: docker.service + container-up.service enabled (per hm.docker_autostart=true)"
    else
      $SUDO systemctl disable container-up.service 2>/dev/null || true
      $SUDO rm -f /etc/systemd/system/container-up.service
      $SUDO systemctl disable docker.service 2>/dev/null || true
      $SUDO systemctl daemon-reload
      echo "[container-init] manual-start mode (set hm.docker_autostart=true in build.json to enable boot-up)"
    fi

    ) || echo "[container-init] FAILED — see errors above, activation continues"
  '';
}
