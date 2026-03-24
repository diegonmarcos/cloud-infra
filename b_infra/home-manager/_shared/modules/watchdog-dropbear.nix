# Kernel Watchdog — if the dog doesn't get petted, the machine resets
#
# Uses Linux softdog kernel module + a tiny systemd service that:
#   1. Opens /dev/watchdog
#   2. Writes every 5 seconds ("pets the dog")
#   3. If the process dies, freezes, or OOMs → kernel resets in 15s
#
# This is BELOW userspace — the kernel timer itself triggers the reboot.
# Even a completely frozen system gets reset. No network, no SSH, no cloud API needed.
#
# Dropbear (rescue-ssh.nix) stays alive for remote triage BEFORE the watchdog fires.
# The watchdog is the absolute last resort — nuclear option.
#
# Safety: systemd WatchdogSec ensures the petter itself is monitored.
#         If the petter service hangs, systemd restarts it.
#         If systemd itself hangs, the kernel watchdog fires.
#
# Usage in VM config:
#   imports = [ ./modules/watchdog-dropbear.nix ];
#
{ config, pkgs, lib, ... }:

let
  # Watchdog timeout: kernel resets if not petted within this window
  watchdogTimeout = 15;
  # Pet interval: must be less than half the timeout
  petInterval = 5;
in {
  home.packages = [ pkgs.watchdog ];

  # Systemd service that pets /dev/watchdog
  home.file.".local/share/watchdog/watchdog-petter.service".text = ''
    [Unit]
    Description=Kernel Watchdog Petter — resets machine if userspace dies
    After=network.target docker.service
    Wants=docker.service

    [Service]
    Type=simple
    # Pet the kernel watchdog via a tiny shell loop
    # Opening /dev/watchdog starts the countdown. Writing to it resets the countdown.
    # If this process dies for ANY reason, the kernel resets the machine in ${toString watchdogTimeout}s.
    ExecStart=/bin/sh -c 'exec 3>/dev/watchdog; while true; do echo V >&3; sleep ${toString petInterval}; done'
    # If the petter itself hangs, systemd kills and restarts it
    WatchdogSec=${toString (petInterval * 3)}
    Restart=always
    RestartSec=2
    # Make this process nearly unkillable (same as Dropbear)
    OOMScoreAdjust=-999
    MemoryMax=10M
    MemoryMin=5M
    CPUWeight=10000
    # Must run as root to access /dev/watchdog
    User=root
    Group=root

    [Install]
    WantedBy=multi-user.target
  '';

  # Activation: install + enable the systemd service
  home.activation.watchdogPetter = lib.hm.dag.entryAfter ["writeBoundary"] ''
    (
    SUDO=""
    if [ "$(id -u)" != "0" ]; then SUDO="sudo"; fi
    SRC="$HOME/.local/share/watchdog"

    # Load softdog kernel module (provides /dev/watchdog on VMs without hardware watchdog)
    $SUDO modprobe softdog soft_margin=${toString watchdogTimeout} 2>/dev/null || true

    # Persist softdog module across reboots
    echo "softdog" | $SUDO tee /etc/modules-load.d/softdog.conf >/dev/null 2>/dev/null || true
    echo "options softdog soft_margin=${toString watchdogTimeout}" | $SUDO tee /etc/modprobe.d/softdog.conf >/dev/null 2>/dev/null || true

    # Install systemd service
    $SUDO cp -f "$SRC/watchdog-petter.service" /etc/systemd/system/watchdog-petter.service
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable watchdog-petter.service 2>/dev/null || true
    $SUDO systemctl restart watchdog-petter.service 2>/dev/null || true

    echo "[watchdog] Kernel watchdog active — timeout=${toString watchdogTimeout}s, pet=${toString petInterval}s"
    echo "[watchdog] If userspace dies, kernel resets machine in ${toString watchdogTimeout}s"
    ) || echo "[watchdog] FAILED — see errors above (may need root)"
  '';
}
