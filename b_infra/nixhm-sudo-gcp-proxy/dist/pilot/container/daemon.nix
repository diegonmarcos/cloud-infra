# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : b_infra/nixhm-sudo-gcp-proxy/src/pilot/container/daemon.nix
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

      # GUARD: refuse to deploy malformed JSON. builtins.toJSON emits ONE
      # object on ONE line; >1 '{'-lines means two modules both declared the
      # home.file (types.lines silently CONCATENATES) — deploying that config
      # kept dockerd crash-looping on oci-mail 2026-07-03. Keep last good
      # config, fail LOUD.
      if [ "$(grep -c '^{' "$DAEMON_SRC")" -gt 1 ]; then
        echo "[docker-daemon] ✗✗✗ REFUSING deploy: daemon.json is CONCATENATED (duplicate home.file writers) — dockerd would crash-loop ✗✗✗" >&2
        logger -p daemon.err -t docker-daemon "daemon.json malformed (concatenated writers) — deploy refused, keeping last good config" 2>/dev/null || true
        exit 1
      fi

      DJNEW=$(cat "$DAEMON_SRC")
      DJOLD=$($SUDO cat "$DAEMON_DEST" 2>/dev/null || true)
      if [ "$DJNEW" != "$DJOLD" ]; then
        # Atomic install (tmp + mv) — a half-written daemon.json bricks dockerd.
        echo "$DJNEW" | $SUDO tee "$DAEMON_DEST.tmp" > /dev/null
        $SUDO mv -f "$DAEMON_DEST.tmp" "$DAEMON_DEST"
        echo "[docker-daemon] daemon.json deployed"

        # A changed daemon.json is INERT until dockerd re-reads it — nothing
        # here reloaded docker, so the youki→runc default-runtime fix silently
        # did NOT apply on oci-mail until a reboot (2026-07-03). Reload (SIGHUP)
        # applies the live-reloadable subset without dropping containers; but
        # runtime-level keys (default-runtime/runtimes) are NOT reloadable — a
        # full docker restart (reboot / container-init) is required, so say so
        # loudly instead of leaving the new config silently ineffective.
        if $SUDO systemctl is-active --quiet docker; then
          $SUDO systemctl reload docker 2>/dev/null \
            && echo "[docker-daemon] docker reloaded (live-reloadable settings applied)" \
            || echo "[docker-daemon] docker reload failed"
          echo "[docker-daemon] ⚠ default-runtime/runtimes changes need a docker RESTART (reboot / container-init) to take effect — verify 'docker info | grep Default Runtime'" >&2
          logger -p daemon.warning -t docker-daemon "daemon.json changed — reloaded; runtime-level keys need a docker restart to apply" 2>/dev/null || true
        fi
      fi
      ) || echo "[docker-daemon] FAILED — see errors above, activation continues"
    '';
  };
}
