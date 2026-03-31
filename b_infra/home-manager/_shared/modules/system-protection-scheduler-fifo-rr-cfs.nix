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
  # Clamp helper: compute then enforce absolute min/max
  clamp = min: max: v: if v < min then min else if v > max then max else v;

  # Sane RAM range: 1GB–36GB
  safeRamMB = clamp 1024 36864 (if ramMB > 0 then ramMB else 1024);

  # Memory budgets derived from VM RAM
  # Reserve 150MB for SSH+WG+earlyoom+watchdog+kernel, rest split between docker+container-init
  reservedMB = 150;
  availableMB = safeRamMB - reservedMB;
  containerInitMaxMB = clamp 64  8192  (availableMB / 4);
  dockerMaxMB        = clamp 128 32768 (availableMB * 3 / 4);

  # Total memory reserved for connectivity slice (SSH+WG+Dropbear)
  connectivityReserveMB = clamp 80 512 (if safeRamMB <= 1024 then 120 else 200);

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
    OOMScoreAdjust=-900
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
    sshd            = { conf = fifoConf 1 10; targets = [ "sshd" "ssh" ]; };
    wg              = { conf = fifoConf 1 10; targets = [ "wg-quick@wg0" ]; };
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

  # ── docker.slice — caps ALL docker processes (daemon + CLI + containers) ──
  dockerSlice = ''
    [Slice]
    Description=Docker workloads slice — daemon, CLI, containers
    CPUQuota=${toString (clamp 50 800 (if safeRamMB <= 2048 then 75 else 150))}%
    MemoryMax=${toString dockerMaxMB}M
    MemoryHigh=${toString (dockerMaxMB * 9 / 10)}M
    IOWeight=50
  '';

  # Wrapper script: /usr/local/bin/docker → runs real docker inside docker.slice
  dockerWrapper = ''
    #!/bin/sh
    # Wrapper: runs docker/docker-compose inside docker.slice (CPU+mem capped)
    exec systemd-run --quiet --scope --slice=docker.slice \
      ionice -c3 nice -n10 /usr/bin/docker "$@"
  '';

  composeWrapper = ''
    #!/bin/sh
    # Wrapper: runs docker compose inside docker.slice (CPU+mem capped)
    exec systemd-run --quiet --scope --slice=docker.slice \
      ionice -c3 nice -n10 /usr/bin/docker compose "$@"
  '';

  buildxWrapper = ''
    #!/bin/sh
    # Wrapper: runs docker buildx inside docker.slice (CPU+mem capped)
    exec systemd-run --quiet --scope --slice=docker.slice \
      ionice -c3 nice -n10 /usr/bin/docker buildx "$@"
  '';

in {
  home.file = dropInFiles // {
    ".local/share/system-protection/connectivity.slice".text = connectivitySlice;
    ".local/share/system-protection/docker.slice".text = dockerSlice;
    ".local/share/system-protection/docker-wrapper.sh" = { text = dockerWrapper; executable = true; };
    ".local/share/system-protection/docker-compose-wrapper.sh" = { text = composeWrapper; executable = true; };
    ".local/share/system-protection/docker-buildx-wrapper.sh" = { text = buildxWrapper; executable = true; };
  };

  home.activation.installScheduler = lib.hm.dag.entryAfter ["installResourceBouncer" "installWatchdogDropbear"] ''
    (
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && exit 0

    SRC="$HOME/.local/share/system-protection"

    # Deploy slices
    $SUDO cp -f "$SRC/connectivity.slice" /etc/systemd/system/connectivity.slice
    $SUDO cp -f "$SRC/docker.slice" /etc/systemd/system/docker.slice

    # Deploy docker wrappers (caps ALL docker CLI processes in docker.slice)
    $SUDO cp -f "$SRC/docker-wrapper.sh" /usr/local/bin/docker-capped
    $SUDO cp -f "$SRC/docker-compose-wrapper.sh" /usr/local/bin/docker-compose-capped
    $SUDO cp -f "$SRC/docker-buildx-wrapper.sh" /usr/local/bin/docker-buildx-capped
    $SUDO chmod +x /usr/local/bin/docker-capped /usr/local/bin/docker-compose-capped /usr/local/bin/docker-buildx-capped

    ${deployScript}

    $SUDO systemctl daemon-reload

    # Restart sshd to pick up FIFO scheduling (CRITICAL — must apply immediately)
    $SUDO systemctl restart sshd 2>/dev/null || $SUDO systemctl restart ssh 2>/dev/null || true

    echo "[scheduler] deployed: connectivity.slice=${toString connectivityReserveMB}MB | FIFO=sshd+wg | RR=earlyoom+watchdog | CFS=docker(${toString dockerMaxMB}MB)+container-init(${toString containerInitMaxMB}MB)"
    ) || echo "[scheduler] FAILED — activation continues"
  '';
}
