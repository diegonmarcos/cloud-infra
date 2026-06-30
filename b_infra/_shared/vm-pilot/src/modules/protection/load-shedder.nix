# protection/load-shedder.nix — memory-pressure load shedder
#
# Guarantees the VM never freezes and WireGuard never goes dark.
#
# A long-running, OOM-immune daemon (in connectivity.slice with WG/SSH, so it
# is itself never starved) watches kernel PSI (Pressure Stall Information) +
# MemAvailable. When the box is about to thrash itself to death it SHEDS ALL
# container load — `systemctl stop docker` — killing every workload while
# WG / sshd / dropbear (separate connectivity.slice, OOMScoreAdjust=-900,
# CPUWeight=10000) keep running. The VM stays up + reachable.
#
# It does NOT reboot (that was watchdog-petter's reboot-loop bug) and does NOT
# auto-restart docker — recovery is `build.sh ship` (no-auto-restart doctrine).
# Killing the workload is always preferable to losing the whole VM + its mesh.
{ config, pkgs, lib, ramMB, ... }:

let
  # Data-driven thresholds from VM RAM.
  #  - PSI memory "some avg10": % of the last 10s that tasks stalled waiting on
  #    memory. >=50 sustained = imminent thrash/freeze. RAM-independent signal.
  #  - MemAvailable floor: hard backstop, scaled to RAM.
  memPsiCrit   = 50;
  # True emergency floor (ramMB/24 ~= 42MB on a 1GB VM), NOT a normal-operation
  # proxy. MemAvailable routinely dips low on small VMs while PSI stays ~0 (the
  # kernel holds RAM as reclaimable page cache) — the old ramMB/12 (~85MB)
  # false-fired at PSI(avg10)=0.18 / MemAvailable=78MB and shed the whole stack
  # on a perfectly healthy box. PSI is the authoritative thrash signal; this
  # floor is only a last-resort backstop for a fast OOM collapse PSI hasn't yet
  # caught. Both arms are debounced (needBreaches) so a transient dip never sheds.
  memAvailCrit = lib.max 40 (lib.min 512 (ramMB / 24));
  interval     = 15;   # seconds between checks
  backoff      = 120;  # seconds to wait after a shed before re-arming
  needBreaches = 3;    # consecutive breaches (~45s) required before shedding
in {
  home.file.".local/share/system-protection/load-shedder.sh" = {
    executable = true;
    text = ''
      #!/bin/sh
      # Load shedder — stop docker before the VM freezes; keep WG/SSH alive.
      MEM_PSI_CRIT=${toString memPsiCrit}
      MEM_AVAIL_CRIT_MB=${toString memAvailCrit}
      INTERVAL=${toString interval}
      BACKOFF=${toString backoff}
      NEED=${toString needBreaches}

      psi_mem_avg10() {
        # /proc/pressure/memory line: "some avg10=12.34 avg60=... total=..."
        awk -F'avg10=' '/^some/ { split($2, a, " "); print a[1]; exit }' \
          /proc/pressure/memory 2>/dev/null || echo 0
      }
      mem_avail_mb() { awk '/^MemAvailable:/ { print int($2/1024); exit }' /proc/meminfo; }

      logger -t load-shedder "armed: shed docker when mem PSI(avg10) >= ''${MEM_PSI_CRIT}%% OR MemAvailable < ''${MEM_AVAIL_CRIT_MB}MB"

      breaches=0
      while :; do
        # Integer part only (portable: no printf %f / locale dependency).
        PSI=$(psi_mem_avg10); PSI_I=''${PSI%%.*}; PSI_I=''${PSI_I:-0}
        AVAIL=$(mem_avail_mb 2>/dev/null || echo 999999)

        if [ "''${PSI_I:-0}" -ge "$MEM_PSI_CRIT" ] || [ "''${AVAIL:-999999}" -lt "$MEM_AVAIL_CRIT_MB" ]; then
          breaches=$((breaches + 1))
          logger -t load-shedder "pressure ''${breaches}/$NEED: PSI(avg10)=''${PSI} MemAvailable=''${AVAIL}MB"
        else
          breaches=0
        fi
        if [ "$breaches" -ge "$NEED" ]; then
          logger -t load-shedder "SHED: mem PSI(avg10)=''${PSI} MemAvailable=''${AVAIL}MB — stopping docker to protect WG/SSH"
          : > /run/load-shedder.fired 2>/dev/null || true
          # Stop the daemon + socket so socket-activation can't revive it; the
          # cgroup teardown kills every container. WG/sshd/dropbear are not
          # docker → unaffected.
          systemctl stop docker.socket 2>/dev/null || true
          systemctl stop docker.service 2>/dev/null || true
          logger -t load-shedder "SHED done — docker stopped, left DOWN (recover via build.sh ship). Backing off ''${BACKOFF}s"
          breaches=0; sleep "$BACKOFF"
        fi
        sleep "$INTERVAL"
      done
    '';
  };

  home.file.".local/share/system-protection/load-shedder.service".text = ''
    [Unit]
    Description=Load shedder — stop docker on memory pressure to keep WireGuard/SSH alive
    After=multi-user.target
    [Service]
    Type=simple
    ExecStart=/opt/scripts/load-shedder.sh
    # Protected like WG/SSH: never starved, OOM-immune, top CPU priority — so it
    # can always run + act precisely when the box is under pressure.
    Slice=connectivity.slice
    OOMScoreAdjust=-999
    MemoryMin=12M
    MemoryMax=32M
    CPUWeight=10000
    Nice=-20
    Restart=always
    RestartSec=3
    User=root
    [Install]
    WantedBy=multi-user.target
  '';

  home.activation.installLoadShedder = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    trap 'echo "[load-shedder] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && echo "[load-shedder] no sudo — skipping" && exit 0

    SRC="$HOME/.local/share/system-protection"
    $SUDO mkdir -p /opt/scripts
    $SUDO cp -f "$SRC/load-shedder.sh" /opt/scripts/load-shedder.sh
    $SUDO chmod +x /opt/scripts/load-shedder.sh
    $SUDO cp -f "$SRC/load-shedder.service" /etc/systemd/system/load-shedder.service
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable load-shedder.service 2>/dev/null || true
    $SUDO systemctl restart load-shedder.service 2>/dev/null || true
    echo "[load-shedder] deployed: PSI>=${toString memPsiCrit}%% | MemAvail<${toString memAvailCrit}MB → stop docker"
    ) || echo "[load-shedder] FAILED — activation continues"
  '';
}
