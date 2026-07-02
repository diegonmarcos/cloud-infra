# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : b_infra/nixhm-sudo-oci-analytics/src/pilot/protection/load-shedder.nix
# ║   Engine : 1_workflows/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

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
  # PSI IS THE ONLY TRIGGER — three signals, no absolute metric. Each is the
  # kernel "some avg10": % of the last 10s that ANY task stalled waiting on that
  # resource. >=50 sustained = imminent thrash/freeze, RAM-independent. The old
  # MemAvailable absolute floor was removed: it routinely false-fired on small
  # VMs (kernel holds RAM as reclaimable cache while PSI stays ~0). If ANY of
  # cpu/mem/io PSI breaches for needBreaches ticks, we shed docker.
  memPsiCrit   = 50;
  cpuPsiCrit   = 50;
  # INCIDENT 2026-07-02 (twice): io gate 30 on SOME false-fired on normal
  # load (~31% idle-loaded); then FULL@30 fired at full=50 during a docker
  # build — a legitimate deploy saturating the small disk while SSH stayed
  # responsive. Deploys routinely reach full io ~50 on these VMs without
  # freezing (WG/sshd hold FIFO + reserved memory). 80 = only a truly dead
  # box; the primary freeze signal remains memPSI (per 2026-06 forensics).
  # TODO(engine): suspend load-shedder during ship/compose windows like the
  # desktop engine's suspend_during_build.system_services.
  ioPsiCrit    = 80;
  interval     = 15;   # seconds between checks
  backoff      = 120;  # seconds to wait after a shed before re-arming
  needBreaches = 3;    # consecutive breaches (~45s) required before shedding
in {
  home.file.".local/share/system-protection/load-shedder.sh" = {
    executable = true;
    text = ''
      #!/bin/sh
      # Load shedder — stop docker before the VM freezes; keep WG/SSH alive.
      # PSI-ONLY: triggers on cpu OR mem OR io PSI (some avg10). No absolute metric.
      MEM_PSI_CRIT=${toString memPsiCrit}
      CPU_PSI_CRIT=${toString cpuPsiCrit}
      IO_PSI_CRIT=${toString ioPsiCrit}
      INTERVAL=${toString interval}
      BACKOFF=${toString backoff}
      NEED=${toString needBreaches}

      # $1 = cpu|memory|io, $2 = some|full — returns integer part of avg10
      # (portable: no printf %f / locale dependency), 0 if unavailable.
      # cpu/mem trigger on 'some'; io triggers on 'full' — 'some io' idles at
      # ~31% on a loaded server and false-shed the whole fleet on 2026-07-02.
      psi_avg10() {
        awk -F'avg10=' -v kind="$2" '$1 ~ "^"kind { split($2, a, " "); print a[1]; exit }' \
          "/proc/pressure/$1" 2>/dev/null || echo 0
      }

      logger -t load-shedder "armed (PSI-only): shed docker when cpuPSI(some)>=''${CPU_PSI_CRIT}%% | memPSI(some)>=''${MEM_PSI_CRIT}%% | ioPSI(FULL)>=''${IO_PSI_CRIT}%%"

      breaches=0
      while :; do
        CPU=$(psi_avg10 cpu some);    CPU_I=''${CPU%%.*}; CPU_I=''${CPU_I:-0}
        MEM=$(psi_avg10 memory some); MEM_I=''${MEM%%.*}; MEM_I=''${MEM_I:-0}
        IO=$(psi_avg10 io full);      IO_I=''${IO%%.*};  IO_I=''${IO_I:-0}

        if [ "$CPU_I" -ge "$CPU_PSI_CRIT" ] || [ "$MEM_I" -ge "$MEM_PSI_CRIT" ] || [ "$IO_I" -ge "$IO_PSI_CRIT" ]; then
          breaches=$((breaches + 1))
          logger -t load-shedder "pressure ''${breaches}/$NEED: cpuPSI=''${CPU} memPSI=''${MEM} ioPSI=''${IO}"
        else
          breaches=0
        fi
        if [ "$breaches" -ge "$NEED" ]; then
          logger -t load-shedder "SHED: cpuPSI=''${CPU} memPSI=''${MEM} ioPSI=''${IO} — stopping docker to protect WG/SSH"
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
    echo "[load-shedder] deployed (PSI-only): cpu>=${toString cpuPsiCrit}%% | mem>=${toString memPsiCrit}%% | io>=${toString ioPsiCrit}%% → stop docker"
    ) || echo "[load-shedder] FAILED — activation continues"
  '';
}
