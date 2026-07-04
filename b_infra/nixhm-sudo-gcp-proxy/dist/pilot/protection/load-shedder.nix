# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : b_infra/nixhm-sudo-gcp-proxy/src/pilot/protection/load-shedder.nix
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
  # MEMORY PSI IS THE ONLY SHED TRIGGER (as this module's header declares).
  # INCIDENT 2026-07-02, THREE false sheds in one night proved cpu/io gates
  # cannot work on a host that is also a BUILD host:
  #   1. io SOME@30  → fired at ~31% normal loaded-server io
  #   2. io FULL@30  → fired at full=50 during a legitimate docker build
  #   3. cpu SOME@50 → fired at 69 while native arm64 image builds pegged
  #      all cores — exactly what a build host is FOR.
  # WG/sshd/dropbear survive cpu+io saturation by design (SCHED_FIFO +
  # MemoryMin island) — only MEMORY thrash can take the box down (2026-06
  # forensics: freezes were user.slice memory pressure, never cpu/io alone).
  # cpu/io are still LOGGED for observability; they never trigger a shed.
  # TODO(engine): suspend load-shedder during ship/compose windows like the
  # desktop engine's suspend_during_build.system_services.
  memPsiCrit   = 50;
  interval     = 15;   # seconds between checks
  backoff      = 120;  # seconds to wait after a shed before re-arming
  needBreaches = 3;    # consecutive breaches (~45s) required before shedding
in {
  home.file.".local/share/system-protection/load-shedder.sh" = {
    executable = true;
    text = ''
      #!/bin/sh
      # Load shedder — stop docker before the VM freezes; keep WG/SSH alive.
      # MEMORY-PSI-ONLY trigger (cpu/io logged for observability, never shed —
      # three false sheds on 2026-07-02 proved them unusable on a build host).
      MEM_PSI_CRIT=${toString memPsiCrit}
      INTERVAL=${toString interval}
      BACKOFF=${toString backoff}
      NEED=${toString needBreaches}

      # $1 = cpu|memory|io, $2 = some|full — returns integer part of avg10
      # (portable: no printf %f / locale dependency), 0 if unavailable.
      psi_avg10() {
        awk -F'avg10=' -v kind="$2" '$1 ~ "^"kind { split($2, a, " "); print a[1]; exit }' \
          "/proc/pressure/$1" 2>/dev/null || echo 0
      }

      logger -t load-shedder "armed (MEMORY-PSI-ONLY): shed docker when memPSI(some)>=''${MEM_PSI_CRIT}%% sustained ''${NEED}x''${INTERVAL}s (cpu/io logged, never shed)"

      breaches=0
      while :; do
        CPU=$(psi_avg10 cpu some);    CPU_I=''${CPU%%.*}; CPU_I=''${CPU_I:-0}
        MEM=$(psi_avg10 memory some); MEM_I=''${MEM%%.*}; MEM_I=''${MEM_I:-0}
        IO=$(psi_avg10 io full);      IO_I=''${IO%%.*};  IO_I=''${IO_I:-0}

        if [ "$MEM_I" -ge "$MEM_PSI_CRIT" ]; then
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

    # VERIFY it actually armed. A silently-unguarded VM is exactly how oci-mail
    # thrashed to 85%% memPSI with the shedder never firing (2026-07-03): the
    # old activation swallowed install/start failures into a bare echo nobody
    # sees, and never confirmed the service came up. Retry once, then FAIL LOUD
    # + drop a persistent marker the health report surfaces.
    $SUDO rm -f /run/load-shedder.deploy-failed 2>/dev/null || true
    if ! $SUDO systemctl is-active --quiet load-shedder.service; then
      sleep 2; $SUDO systemctl restart load-shedder.service 2>/dev/null || true; sleep 2
    fi
    if $SUDO systemctl is-active --quiet load-shedder.service; then
      echo "[load-shedder] ARMED ✓ (MEMORY-PSI-ONLY: mem>=${toString memPsiCrit}%% sustained → stop docker)"
    else
      echo "[load-shedder] ✗✗✗ FAILED TO ARM — VM UNPROTECTED against memory thrash ✗✗✗" >&2
      $SUDO sh -c 'echo "load-shedder inactive after HM activation $(date -u +%%FT%%TZ)" > /run/load-shedder.deploy-failed' 2>/dev/null || true
      logger -p daemon.err -t load-shedder "DEPLOY FAILED — service inactive after activation; VM UNPROTECTED against memory thrash" 2>/dev/null || true
    fi
    ) || echo "[load-shedder] activation error (see above) — check 'systemctl status load-shedder'"
  '';
}
