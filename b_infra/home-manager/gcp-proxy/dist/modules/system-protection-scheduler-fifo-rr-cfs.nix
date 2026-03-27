# system-protection-scheduler.nix — CPU scheduler lane assignments
#
# Three lanes, kernel-enforced:
#   FIFO (lane 1): absolute priority, preempts everything — SSH, WG, Dropbear
#   RR   (lane 2): real-time round-robin — earlyoom, watchdog
#   CFS  (lane 3): normal fair share — Docker, containers, everything else
#
# Drop-in configs deployed to /etc/systemd/system/<service>.d/scheduler.conf
# Applied on every home-manager activation + sshd restarted to pick up changes.
{ config, pkgs, lib, ramMB, ... }:

let
  # Memory budgets derived from VM RAM
  # Reserve 150MB for SSH+WG+earlyoom+watchdog+kernel, rest split between docker+container-init
  reservedMB = 150;
  availableMB = ramMB - reservedMB;
  containerInitMaxMB = availableMB / 4;     # container-init orchestrator gets 25%
  dockerMaxMB        = availableMB * 3 / 4; # Docker daemon + containers get 75%

  # Total memory reserved for connectivity slice (SSH+WG+Dropbear)
  connectivityReserveMB = if ramMB <= 1024 then 120 else 200;

  # ── connectivity.slice — kernel-guaranteed memory for SSH/WG/Dropbear ──
  connectivitySlice = ''
    [Slice]
    Description=Protected connectivity slice — SSH, WG, Dropbear
    MemoryMin=${toString connectivityReserveMB}M
    MemoryLow=${toString connectivityReserveMB}M
    CPUWeight=10000
    IOWeight=1000
  '';

  # ── Lane 1: FIFO — never waits, preempts ALL normal processes ───────
  fifoConf = priority: mem: ''
    [Service]
    Slice=connectivity.slice
    CPUSchedulingPolicy=fifo
    CPUSchedulingPriority=${toString priority}
    IOSchedulingClass=realtime
    IOSchedulingPriority=0
    OOMScoreAdjust=-1000
    OOMPolicy=continue
    MemoryMin=${toString mem}M
    Nice=-20
  '';

  # ── Lane 2: RR — real-time but time-sliced among RR peers ──────────
  rrConf = priority: ''
    [Service]
    CPUSchedulingPolicy=rr
    CPUSchedulingPriority=${toString priority}
    IOSchedulingClass=best-effort
    IOSchedulingPriority=0
    OOMScoreAdjust=-999
    OOMPolicy=continue
    Nice=-20
  '';

  # ── Lane 3: CFS — normal, with caps to prevent starvation ──────────
  cfsConf = cpuQuota: nice: oomScore: memMax: ''
    [Service]
    CPUQuota=${toString cpuQuota}%
    Nice=${toString nice}
    OOMScoreAdjust=${toString oomScore}
    IOWeight=50
    MemoryMax=${toString memMax}M
    MemoryHigh=${toString (memMax * 9 / 10)}M
  '';

  # ── Assignments ─────────────────────────────────────────────────────
  # service-name → { lane, conf }
  #
  # FIFO (lane 1): connectivity — MUST always respond
  # RR   (lane 2): protection daemons — must run but can share
  # CFS  (lane 3): workloads — capped so they can't starve lanes 1-2

  assignments = {
    # ── FIFO: connectivity (non-negotiable) ───────────────────────────
    sshd            = { conf = fifoConf 1 50; targets = [ "sshd" "ssh" ]; };
    wg              = { conf = fifoConf 1 30; targets = [ "wg-quick@wg0" ]; };
    # rescue-ssh (Dropbear) is set in watchdog-dropbear.nix directly

    # ── RR: protection daemons ────────────────────────────────────────
    earlyoom        = { conf = rrConf 1; targets = [ "earlyoom" ]; };
    watchdog        = { conf = rrConf 1; targets = [ "watchdog-petter" ]; };

    # ── CFS: workloads (capped) ───────────────────────────────────────
    container-init  = { conf = cfsConf 70 10 200 containerInitMaxMB;  targets = [ "container-init" ]; };
    docker          = { conf = cfsConf 80 5  500 dockerMaxMB;          targets = [ "docker" ]; };
  };

  # Generate home.file entries for each drop-in
  mkDropIn = name: spec:
    lib.nameValuePair
      ".local/share/system-protection/scheduler-${name}.conf"
      { text = spec.conf; };

  dropInFiles = lib.mapAttrs' mkDropIn assignments;

  # Generate activation script that deploys all drop-ins
  deployScript = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: spec:
    lib.concatMapStringsSep "\n" (target: ''
      if $SUDO systemctl cat "${target}.service" >/dev/null 2>&1 || \
         $SUDO systemctl cat "${target}" >/dev/null 2>&1; then
        $SUDO mkdir -p "/etc/systemd/system/${target}.service.d"
        $SUDO cp -f "$SRC/scheduler-${name}.conf" "/etc/systemd/system/${target}.service.d/scheduler.conf"
        echo "[scheduler] ${target} → ${name}"
      fi
    '') spec.targets
  ) assignments);

in {
  home.file = dropInFiles // {
    ".local/share/system-protection/connectivity.slice".text = connectivitySlice;
  };

  home.activation.installScheduler = lib.hm.dag.entryAfter ["installResourceBouncer" "installWatchdogDropbear"] ''
    (
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && exit 0

    SRC="$HOME/.local/share/system-protection"

    # Deploy connectivity.slice — kernel-guaranteed memory for SSH/WG/Dropbear
    $SUDO cp -f "$SRC/connectivity.slice" /etc/systemd/system/connectivity.slice

    ${deployScript}

    $SUDO systemctl daemon-reload

    # Restart sshd to pick up FIFO scheduling (CRITICAL — must apply immediately)
    $SUDO systemctl restart sshd 2>/dev/null || $SUDO systemctl restart ssh 2>/dev/null || true

    echo "[scheduler] deployed: connectivity.slice=${toString connectivityReserveMB}MB | FIFO=sshd+wg | RR=earlyoom+watchdog | CFS=docker(${toString dockerMaxMB}MB)+container-init(${toString containerInitMaxMB}MB)"
    ) || echo "[scheduler] FAILED — activation continues"
  '';
}
