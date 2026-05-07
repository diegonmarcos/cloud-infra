# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : b_infra/nixhm-sudo-oci-mail/src/pilot/container/daemon-resources.nix
# ║   Engine : 1_workflows/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Docker Daemon — resource limits (documentation only)
#
# Docker resource limits are NOT configured in daemon.json.
# They are managed by systemd drop-ins in system-protection-resource-bouncer.nix,
# which calculates limits dynamically from VM RAM specs in cloud-data.
#
# ┌─────────────────────────────────────────────────────────────────┐
# │ This file exists for organizational consistency across the      │
# │ container-control-daemon module family. No active config here.  │
# └─────────────────────────────────────────────────────────────────┘
#
# === Actual enforcement ===
#
# Deployed to: /etc/systemd/system/docker.service.d/memory-cap.conf
# Source:      system-protection-resource-bouncer.nix
#
#   MemoryMax       = RAM - 350MB (1GB VMs) to RAM - 1GB (24GB VMs)
#   MemoryHigh      = MemoryMax × 90%  (triggers kernel memory pressure)
#   OOMScoreAdjust  = 500              (high priority for OOM killer)
#
# CPUQuota = 80% is in the docker.service unit (container-control-init.nix)
#
{ config, pkgs, lib, ... }:

{
  home.file.".local/share/system-protection/docker-daemon.json".text = builtins.toJSON {
    default-ulimits = {
      nofile = { Name = "nofile"; Hard = 65536; Soft = 65536; };
    };
    log-driver = "json-file";
    log-opts = {
      max-size = "10m";
      max-file = "3";
    };
  };

  home.activation.installDockerDaemonConfig = lib.hm.dag.entryAfter ["writeBoundary"] ''
    (
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && exit 0

    SRC="$HOME/.local/share/system-protection/docker-daemon.json"
    if [ -f "$SRC" ]; then
      $SUDO mkdir -p /etc/docker
      $SUDO cp -f "$SRC" /etc/docker/daemon.json
      echo "[docker-daemon] daemon.json deployed"
    fi
    ) || echo "[docker-daemon] FAILED"
  '';
}
