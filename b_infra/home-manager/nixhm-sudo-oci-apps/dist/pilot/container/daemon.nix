# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : b_infra/home-manager/nixhm-sudo-oci-apps/src/pilot/container/daemon.nix
# ║   Engine : 1_workflows/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Container Control Daemon — orchestrator for Docker daemon.json configuration
#
# Defines a custom HM option (docker.daemon.settings) that sub-modules
# contribute to. The merged attrset is serialized to daemon.json and
# deployed to /etc/docker/daemon.json via activation script.
#
# Sub-modules:
#   container-control-daemon-security.nix   — process isolation
#   container-control-daemon-firewall.nix   — iptables policy
#   container-control-daemon-network.nix    — DNS, topology
#   container-control-daemon-resources.nix  — pointer to system-protection
{ config, pkgs, lib, ... }:

{
  imports = [
    ./daemon-security.nix
    ./daemon-firewall.nix
    ./daemon-network.nix
    ./daemon-resources.nix
  ];

  # ── Custom option: sub-modules merge into this ─────────────────
  options.docker.daemon.settings = lib.mkOption {
    type = lib.types.attrs;
    default = {};
    description = "Docker daemon.json settings — merged from sub-modules";
  };

  # ── Generate daemon.json from merged settings ──────────────────
  config = {
    home.file.".local/share/container-init/daemon.json".text =
      builtins.toJSON config.docker.daemon.settings;

    # ── Activation: deploy daemon.json to /etc/docker/ ───────────
    home.activation.installDaemonJson = lib.hm.dag.entryAfter ["linkGeneration"] ''
      (
      trap 'echo "[docker-daemon] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
      SUDO=""
      for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
        [ -x "$p" ] && SUDO="$p" && break
      done
      if [ -z "$SUDO" ]; then
        echo "[docker-daemon] WARNING: sudo not found — skipping"
        exit 0
      fi

      DAEMON_SRC="$HOME/.local/share/container-init/daemon.json"
      DAEMON_DEST="/etc/docker/daemon.json"
      $SUDO mkdir -p /etc/docker
      DJNEW=$(cat "$DAEMON_SRC")
      DJOLD=$($SUDO cat "$DAEMON_DEST" 2>/dev/null || true)
      if [ "$DJNEW" != "$DJOLD" ]; then
        echo "$DJNEW" | $SUDO tee "$DAEMON_DEST" > /dev/null
        echo "[docker-daemon] daemon.json deployed"
      fi
      ) || echo "[docker-daemon] FAILED — see errors above, activation continues"
    '';
  };
}
