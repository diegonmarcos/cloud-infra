{ config, pkgs, lib, ... }:

let
  # Resolve dockerd path at nix eval time — no runtime searching
  dockerdBin = "${pkgs.docker}/bin/dockerd";
in {
  home.file.".local/share/docker-service/docker.service".text = ''
    [Unit]
    Description=Docker Application Container Engine (nix)
    After=network-online.target firewall.service
    Wants=network-online.target
    Requires=firewall.service

    [Service]
    Type=notify
    # RESCUE MODE: check GCP metadata for rescue-mode flag.
    # If set, Docker refuses to start — SSH stays alive for manual recovery.
    # Enter:  gcloud compute instances add-metadata VM --metadata=rescue-mode=true
    # Exit:   gcloud compute instances remove-metadata VM --keys=rescue-mode
    ExecStartPre=/bin/bash -c '\
      RESCUE=$(curl -sf -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/attributes/rescue-mode" 2>/dev/null || echo ""); \
      if [ "$RESCUE" = "true" ]; then \
        echo "[docker] RESCUE MODE — Docker blocked. Remove rescue-mode metadata to resume."; \
        exit 1; \
      fi'
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

    # NO [Install] section — Docker does NOT autostart on boot.
    # container-init.service is the sole entry point: it starts Docker
    # first, then brings up containers sequentially to avoid OOM.
  '';

  # Docker daemon config — iptables disabled, we manage all rules in firewall.nix
  home.file.".local/share/docker-service/daemon.json".text = builtins.toJSON {
    iptables = false;
    ip6tables = false;
  };

  home.activation.dockerService = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    trap 'echo "[docker-service] FAILED at line $LINENO (''${FUNCNAME[0]:-main}): $BASH_COMMAND" >&2' ERR
    DOCKER_LOG="[docker-service]"

    # Find sudo (not in PATH during home-manager activation)
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    if [ -z "$SUDO" ]; then
      echo "$DOCKER_LOG WARNING: sudo not found — skipping docker service setup"
      exit 0
    fi

    # Verify dockerd exists (nix store path baked at eval time)
    if [ ! -x "${dockerdBin}" ]; then
      echo "$DOCKER_LOG WARNING: ${dockerdBin} not found — skipping"
      exit 0
    fi

    # Deploy service unit (dockerd path already baked in by nix)
    UNIT_SRC="$HOME/.local/share/docker-service/docker.service"
    UNIT_DEST="/etc/systemd/system/docker.service"
    if [ ! -f "$UNIT_SRC" ]; then
      echo "$DOCKER_LOG WARNING: unit template not found at $UNIT_SRC"
      exit 0
    fi

    NEW_UNIT=$(cat "$UNIT_SRC")

    CURRENT=""
    if $SUDO test -f "$UNIT_DEST"; then
      CURRENT=$($SUDO cat "$UNIT_DEST" 2>/dev/null || true)
    fi

    if [ "$NEW_UNIT" != "$CURRENT" ]; then
      echo "$DOCKER_LOG docker.service changed — deploying"
      echo "$NEW_UNIT" | $SUDO tee "$UNIT_DEST" > /dev/null
      $SUDO systemctl daemon-reload
      $SUDO systemctl restart docker 2>/dev/null || $SUDO systemctl start docker
      echo "$DOCKER_LOG Docker restarted"
    fi

    # Docker is NOT enabled on boot — container-init.service handles startup.
    # Explicitly disable to prevent leftover symlinks from re-enabling it.
    $SUDO systemctl disable docker 2>/dev/null || true

    # Deploy daemon.json
    DAEMON_SRC="$HOME/.local/share/docker-service/daemon.json"
    DAEMON_DEST="/etc/docker/daemon.json"
    if [ -f "$DAEMON_SRC" ]; then
      $SUDO mkdir -p /etc/docker
      DAEMON_CURRENT=""
      if $SUDO test -f "$DAEMON_DEST"; then
        DAEMON_CURRENT=$($SUDO cat "$DAEMON_DEST" 2>/dev/null || true)
      fi
      DAEMON_NEW=$(cat "$DAEMON_SRC")
      if [ "$DAEMON_NEW" = "$DAEMON_CURRENT" ]; then
        echo "$DOCKER_LOG daemon.json unchanged — skipping"
      else
        echo "$DAEMON_NEW" | $SUDO tee "$DAEMON_DEST" > /dev/null
        echo "$DOCKER_LOG daemon.json deployed (iptables: false)"
        # Restart Docker to pick up new daemon.json
        if $SUDO systemctl is-active docker >/dev/null 2>&1; then
          $SUDO systemctl restart docker
          echo "$DOCKER_LOG Docker restarted for daemon.json"
        fi
      fi
    fi
    ) || echo "[docker-service] FAILED — see errors above, activation continues"
  '';
}
