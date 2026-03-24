# Rescue SSH — untouchable supervisor that NEVER dies
#
# Dropbear SSH on port 2200, protected by:
#   - OOMScoreAdjust=-1000 (kernel will NEVER kill this, even before init)
#   - MemoryMax=30M (hard cap — it only needs ~2MB but we give headroom)
#   - MemoryMin=20M (kernel guarantees this memory is reserved)
#   - CPUWeight=10000 (highest priority)
#
# When Docker OOMs the main SSH (port 22), connect via:
#   ssh -p 2200 gcp-proxy
#
# Uses the same authorized_keys as OpenSSH.
#
# Usage in VM config:
#   (import ./modules/rescue-ssh.nix { inherit config pkgs lib; port = 2200; })
#
{ config, pkgs, lib, port ? 2222, ... }:

let
  dropbearBin = "${pkgs.dropbear}/bin/dropbear";
  dropbearKeyBin = "${pkgs.dropbear}/bin/dropbearkey";
in {
  home.packages = [ pkgs.dropbear ];

  home.file.".local/share/rescue-ssh/rescue-ssh.service".text = ''
    [Unit]
    Description=Rescue SSH (Dropbear on port ${toString port}) — UNTOUCHABLE
    After=network.target
    Before=docker.service

    [Service]
    Type=simple
    ExecStartPre=/opt/scripts/rescue-ssh-setup.sh
    ExecStart=${dropbearBin} -F -E -p ${toString port} -r /etc/dropbear/dropbear_ed25519_host_key
    Restart=always
    RestartSec=2

    # UNTOUCHABLE — kernel OOM killer will never touch this
    OOMScoreAdjust=-1000
    OOMPolicy=continue
    MemoryMin=20M
    MemoryMax=30M
    MemoryHigh=25M
    CPUWeight=10000

    # Minimal footprint
    Nice=-20

    [Install]
    WantedBy=multi-user.target
  '';

  home.file.".local/share/rescue-ssh/rescue-ssh-setup.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      # Generate host key if missing + sync authorized_keys
      set -euo pipefail

      mkdir -p /etc/dropbear
      if [ ! -f /etc/dropbear/dropbear_ed25519_host_key ]; then
        ${dropbearKeyBin} -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key
        echo "[rescue-ssh] Generated ed25519 host key"
      fi

      # Dropbear reads ~/.ssh/authorized_keys by default — same as OpenSSH
      echo "[rescue-ssh] Ready on port ${toString port}"
    '';
  };

  home.activation.installRescueSsh = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && exit 0

    SRC="$HOME/.local/share/rescue-ssh"

    $SUDO mkdir -p /opt/scripts /etc/dropbear
    $SUDO cp -f "$SRC/rescue-ssh-setup.sh" /opt/scripts/rescue-ssh-setup.sh
    $SUDO chmod +x /opt/scripts/rescue-ssh-setup.sh
    $SUDO cp -f "$SRC/rescue-ssh.service" /etc/systemd/system/rescue-ssh.service

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable rescue-ssh.service 2>/dev/null || true
    $SUDO systemctl restart rescue-ssh.service 2>/dev/null || true

    echo "[rescue-ssh] Dropbear on port ${toString port} — OOMScore=-1000 (untouchable)"
    ) || echo "[rescue-ssh] FAILED — see errors above"
  '';
}
