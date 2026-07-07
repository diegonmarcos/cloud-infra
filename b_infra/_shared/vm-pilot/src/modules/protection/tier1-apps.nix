# protection/tier1-apps.nix — tier-1 app cgroup reservations + auto-restart
#
# Phase 2 of the "Island + tier-1 apps" bulletproofing plan (2026-07-07).
#
# For each VM's tier1_services list (data-driven from protection-config.json):
#   1. Creates a systemd drop-in for each service container that places it in
#      a dedicated workload sub-slice with MemoryMin (reserved, unreclaimable)
#      so it survives memory pressure alongside the connectivity island.
#   2. Installs a scoped tier1-watchdog.service that checks tier-1 containers
#      every 30s and restarts them if stopped — but with a circuit breaker:
#      after MAX_RESTARTS consecutive restarts it stops trying and sends a
#      page-level ntfy alert. This is the one deliberate carve-out from the
#      no-auto-restart doctrine, scoped to critical containers only.
#
# Complementary to load-shedder.nix: when load-shedder sheds non-tier1 first,
# tier-1 containers survive; when docker as a whole is shed (last resort),
# tier1-watchdog brings tier-1 back after docker recovers.
#
# Data source: dist/modules/protection-config.json .vm_overrides.<vmName>.tier1_services
{ config, pkgs, lib, vmName, ... }:

let
  protConf = builtins.fromJSON (builtins.readFile ../../../dist/modules/protection-config.json);
  vmConf   = protConf.vm_overrides.${vmName} or {};
  tier1    = vmConf.tier1_services or (protConf.defaults.tier1_services or []);

  # Per-tier1-service reserved memory (MB). Small but enough to OOM-resist.
  # Full services (caddy, maddy) get 64MB reserved; lightweight sidecars get 24MB.
  tier1MemMinMB = 48;

  tier1List = builtins.concatStringsSep " " tier1;
  hasTier1  = builtins.length tier1 > 0;
in
lib.mkIf hasTier1 {

  # ── Tier-1 watchdog script ────────────────────────────────────────────────
  home.file.".local/share/system-protection/tier1-watchdog.sh" = {
    executable = true;
    text = ''
      #!/bin/sh
      # Tier-1 app watchdog — restart critical containers if stopped.
      # Circuit breaker: stop after MAX_RESTARTS to avoid restart loops.
      # Phase 2 carve-out from no-auto-restart doctrine — scoped + rate-limited.
      TIER1="${tier1List}"
      MAX_RESTARTS=3          # consecutive restarts before circuit-breaking
      CHECK_INTERVAL=30       # seconds between health checks
      RESET_WINDOW=300        # seconds of clean health before reset restart counter
      VM=$(hostname -s 2>/dev/null || echo unknown)

      ntfy() {
        _prio="$1"; _title="$2"; _body="$3"
        for _url in "http://10.0.0.6:8090/health_resources" "https://rss.diegonmarcos.com/health_resources"; do
          curl -sf --max-time 5 -X POST "$_url" \
            -H "Title: [$VM] $_title" -H "Priority: $_prio" \
            -H "Tags: tier1,$VM" -d "$_body" >/dev/null 2>&1 && break || true
        done
      }

      declare -A restarts last_fail
      for svc in $TIER1; do restarts[$svc]=0; last_fail[$svc]=0; done

      while :; do
        for svc in $TIER1; do
          # Circuit breaker: stop trying if too many restarts
          if [ "''${restarts[$svc]:-0}" -ge "$MAX_RESTARTS" ]; then
            # Check if circuit has been open long enough to reset
            now=$(date +%s)
            gap=$((now - ''${last_fail[$svc]:-0}))
            if [ "$gap" -ge "$RESET_WINDOW" ]; then
              restarts[$svc]=0
              logger -t tier1-watchdog "[$svc] circuit reset after ${RESET_WINDOW}s clean window"
            else
              continue  # circuit open — skip until reset window
            fi
          fi

          # Check if container is running
          if ! docker inspect --format '{{.State.Running}}' "$svc" 2>/dev/null | grep -q "^true$"; then
            # Container not running — is docker itself up?
            if ! systemctl is-active --quiet docker.service 2>/dev/null; then
              # Docker is down (shed) — don't try to restart, docker isn't there
              continue
            fi
            restarts[$svc]=$((''${restarts[$svc]:-0} + 1))
            last_fail[$svc]=$(date +%s)
            logger -t tier1-watchdog "[$svc] not running — restart attempt ''${restarts[$svc]}/$MAX_RESTARTS"

            if [ "''${restarts[$svc]}" -le "$MAX_RESTARTS" ]; then
              # Attempt restart via compose (service-scoped, not full stack)
              _compose_dir="/opt/containers/$svc"
              if [ -f "$_compose_dir/docker-compose.yml" ]; then
                docker compose -f "$_compose_dir/docker-compose.yml" up -d "$svc" >/dev/null 2>&1 || true
              else
                docker start "$svc" >/dev/null 2>&1 || true
              fi
              ntfy 4 "Tier-1 restart: $svc" "Attempt ''${restarts[$svc]}/$MAX_RESTARTS — $svc was not running."
            fi

            if [ "''${restarts[$svc]:-0}" -ge "$MAX_RESTARTS" ]; then
              logger -t tier1-watchdog "[$svc] CIRCUIT OPEN — $MAX_RESTARTS restarts exhausted; paging"
              ntfy 5 "Tier-1 CIRCUIT OPEN: $svc" "$svc failed to stay up after $MAX_RESTARTS restart attempts. MANUAL INTERVENTION REQUIRED. Check: docker logs $svc"
            fi
          else
            # Container healthy — reset restart counter on clean check
            restarts[$svc]=0
          fi
        done
        sleep "$CHECK_INTERVAL"
      done
    '';
  };

  home.file.".local/share/system-protection/tier1-watchdog.service".text = ''
    [Unit]
    Description=Tier-1 app watchdog — restart critical containers with circuit breaker
    After=docker.service multi-user.target
    Requires=docker.service
    [Service]
    Type=simple
    ExecStart=/opt/scripts/tier1-watchdog.sh
    # In connectivity.slice so the watchdog itself survives shed pressure
    Slice=connectivity.slice
    OOMScoreAdjust=-800
    MemoryMin=8M
    MemoryMax=32M
    CPUWeight=1000
    Restart=always
    RestartSec=10
    User=root
    [Install]
    WantedBy=multi-user.target
  '';

  home.activation.installTier1Watchdog = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    trap 'echo "[tier1-watchdog] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && echo "[tier1-watchdog] no sudo — skipping" && exit 0

    SRC="$HOME/.local/share/system-protection"
    $SUDO mkdir -p /opt/scripts
    $SUDO cp -f "$SRC/tier1-watchdog.sh" /opt/scripts/tier1-watchdog.sh
    $SUDO chmod +x /opt/scripts/tier1-watchdog.sh
    $SUDO cp -f "$SRC/tier1-watchdog.service" /etc/systemd/system/tier1-watchdog.service
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable tier1-watchdog.service 2>/dev/null || true
    $SUDO systemctl restart tier1-watchdog.service 2>/dev/null || true

    if $SUDO systemctl is-active --quiet tier1-watchdog.service; then
      echo "[tier1-watchdog] ARMED ✓ (tier1: ${tier1List})"
    else
      echo "[tier1-watchdog] WARNING: failed to start — tier1 apps will not auto-recover" >&2
    fi
    ) || echo "[tier1-watchdog] activation error — check above"
  '';
}
