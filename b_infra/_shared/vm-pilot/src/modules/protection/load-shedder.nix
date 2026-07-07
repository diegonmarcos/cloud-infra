# protection/load-shedder.nix — memory-pressure load shedder
#
# Guarantees the VM never freezes and WireGuard never goes dark.
#
# A long-running, OOM-immune daemon (in connectivity.slice with WG/SSH, so it
# is itself never starved) watches kernel PSI (Pressure Stall Information).
# When the box is about to thrash itself to death it SHEDS container load in
# GRADUATED steps, protecting tier-1 apps (maddy/caddy etc.) until last resort:
#
#   PSI ≥ warn:  notify health_resources (no action)
#   PSI ≥ crit × N: stop NON-tier-1 containers + notify health_resources:crit
#   PSI ≥ page × N: stop ALL (systemctl stop docker) + notify page-level
#
# It does NOT reboot (watchdog-petter's reboot-loop bug) and does NOT
# auto-restart docker — recovery is `build.sh ship` (no-auto-restart doctrine).
# Tier-1 services configured in protection-config.json per VM.
#
# P4: thresholds are data-driven from dist/modules/protection-config.json
# with per-VM overrides — never hardcoded in this file.
{ config, pkgs, lib, ramMB, vmName, ... }:

let
  # Data-driven thresholds from protection-config.json (P4).
  # builtins.fromJSON reads at build time → baked into script; redeploy to change.
  protConf = builtins.fromJSON (builtins.readFile ../../../dist/modules/protection-config.json);
  vmConf   = protConf.vm_overrides.${vmName} or {};
  defaults = protConf.defaults;

  memPsiWarn   = vmConf.mem_psi_warn   or defaults.mem_psi_warn;    # notify only
  memPsiCrit   = vmConf.mem_psi_crit   or defaults.mem_psi_crit;    # shed non-tier1
  memPsiPage   = vmConf.mem_psi_page   or defaults.mem_psi_page;    # shed everything
  interval     = vmConf.interval_secs  or defaults.interval_secs;
  backoff      = vmConf.backoff_secs   or defaults.backoff_secs;
  needBreaches = vmConf.need_breaches  or defaults.need_breaches;

  # Tier-1 services that survive graduated shed (stopped only on page-level).
  tier1Services = vmConf.tier1_services or defaults.tier1_services;
  tier1List     = builtins.concatStringsSep " " tier1Services;

  # MEMORY PSI IS THE ONLY SHED TRIGGER.
  # INCIDENT 2026-07-02, THREE false sheds proved cpu/io gates unusable on
  # build hosts. cpu/io still LOGGED for observability; never shed.
in {
  home.file.".local/share/system-protection/load-shedder.sh" = {
    executable = true;
    text = ''
      #!/bin/sh
      # Load shedder — graduated memory-pressure protection.
      # MEMORY-PSI-ONLY trigger (cpu/io logged, never shed — three false sheds 2026-07-02).
      # P1: notifies ntfy on every action (shed/warn/recovery).
      # Phase 2: graduated response — warn → shed non-tier1 → shed all.
      # Tier-1 services (defined in protection-config.json) survive until last resort.
      MEM_PSI_WARN=${toString memPsiWarn}
      MEM_PSI_CRIT=${toString memPsiCrit}
      MEM_PSI_PAGE=${toString memPsiPage}
      INTERVAL=${toString interval}
      BACKOFF=${toString backoff}
      NEED=${toString needBreaches}
      TIER1_SERVICES="${tier1List}"    # space-separated container names to protect
      VM=$(hostname -s 2>/dev/null || echo unknown)

      # $1 = cpu|memory|io, $2 = some|full — integer part of avg10, 0 if unavailable
      psi_avg10() {
        awk -F'avg10=' -v kind="$2" '$1 ~ "^"kind { split($2, a, " "); print a[1]; exit }' \
          "/proc/pressure/$1" 2>/dev/null || echo 0
      }

      # P1: notify ntfy — try WG-direct first (10.0.0.6=oci-apps:8090), then public edge.
      # $1=priority(1-5) $2=topic $3=title $4=body
      ntfy_send() {
        _prio="$1"; _topic="$2"; _title="$3"; _body="$4"
        _sent=false
        for _url in "http://10.0.0.6:8090/$_topic" "https://rss.diegonmarcos.com/$_topic"; do
          if curl -sf --max-time 5 -X POST "$_url" \
               -H "Title: [$VM] $_title" \
               -H "Priority: $_prio" \
               -H "Tags: shedder,$VM" \
               -d "$_body" >/dev/null 2>&1; then
            _sent=true; break
          fi
        done
        # If ntfy is unreachable (e.g. we just shed docker on oci-apps), log it — not fatal.
        "$_sent" || logger -p daemon.warn -t load-shedder "ntfy notify failed (non-fatal): [$_title] $_body"
      }

      # Graduated shed step 1: stop non-tier1 containers only.
      shed_non_tier1() {
        if [ -z "$TIER1_SERVICES" ]; then
          # No tier1 services configured — fall through to full shed
          return 1
        fi
        _running=$(docker ps --format '{{.Names}}' 2>/dev/null || echo "")
        _to_stop=""
        for _c in $_running; do
          _is_t1=false
          for _t in $TIER1_SERVICES; do
            [ "$_c" = "$_t" ] && _is_t1=true && break
          done
          "$_is_t1" || _to_stop="$_to_stop $_c"
        done
        if [ -n "$_to_stop" ]; then
          logger -t load-shedder "SHED-CRIT: stopping non-tier1:$_to_stop (keeping: $TIER1_SERVICES)"
          # shellcheck disable=SC2086
          docker stop $_to_stop 2>/dev/null || true
          return 0
        fi
        # All running containers are tier-1 — escalate to full shed
        return 1
      }

      logger -t load-shedder "armed: warn>=${toString memPsiWarn}%% crit>=${toString memPsiCrit}%% page>=${toString memPsiPage}%% tier1=[${tier1List}]"

      breaches_crit=0
      breaches_page=0
      shed_level=0   # 0=normal 1=non-tier1-shed 2=full-shed

      while :; do
        CPU=$(psi_avg10 cpu some);    CPU_I=''${CPU%%.*}; CPU_I=''${CPU_I:-0}
        MEM=$(psi_avg10 memory some); MEM_I=''${MEM%%.*}; MEM_I=''${MEM_I:-0}
        IO=$(psi_avg10 io full);      IO_I=''${IO%%.*};  IO_I=''${IO_I:-0}

        # ── Warn level (no action, just notify) ───────────────────────────
        if [ "$MEM_I" -ge "$MEM_PSI_WARN" ] && [ "$MEM_I" -lt "$MEM_PSI_CRIT" ] && [ "$shed_level" -eq 0 ]; then
          logger -t load-shedder "WARN: memPSI=''${MEM} (threshold=$MEM_PSI_WARN)"
          ntfy_send 3 "health_resources" "Memory pressure WARN" "memPSI=''${MEM}%% cpuPSI=''${CPU}%% ioPSI=''${IO}%%"
        fi

        # ── Crit level: track breaches ────────────────────────────────────
        if [ "$MEM_I" -ge "$MEM_PSI_CRIT" ] && [ "$MEM_I" -lt "$MEM_PSI_PAGE" ]; then
          breaches_crit=$((breaches_crit + 1))
          breaches_page=0
          logger -t load-shedder "CRIT breach ''${breaches_crit}/$NEED: memPSI=''${MEM} cpuPSI=''${CPU}"
        elif [ "$MEM_I" -ge "$MEM_PSI_PAGE" ]; then
          breaches_page=$((breaches_page + 1))
          breaches_crit=0
          logger -t load-shedder "PAGE breach ''${breaches_page}/$NEED: memPSI=''${MEM} (CRITICAL level)"
        else
          # Pressure subsided — reset + notify recovery if we had shed
          if [ "$shed_level" -gt 0 ]; then
            logger -t load-shedder "RECOVERY: memPSI=''${MEM} — pressure resolved (shed_level was $shed_level)"
            ntfy_send 4 "health_resources" "Memory pressure RESOLVED" "memPSI now ''${MEM}%% (was shed_level=$shed_level). Manual docker restart required for non-tier1."
            shed_level=0
          fi
          breaches_crit=0; breaches_page=0
        fi

        # ── Page-level shed: stop everything ─────────────────────────────
        if [ "$breaches_page" -ge "$NEED" ] && [ "$shed_level" -lt 2 ]; then
          logger -t load-shedder "SHED-PAGE: memPSI=''${MEM} — stopping ALL docker (last resort)"
          ntfy_send 5 "health_resources" "LOAD SHED — ALL DOCKER STOPPED" "LAST RESORT: memPSI=''${MEM}%% ≥ $MEM_PSI_PAGE%% × $NEED checks. ALL containers stopped. Recover: build.sh ship."
          : > /run/load-shedder.fired 2>/dev/null || true
          systemctl stop docker.socket 2>/dev/null || true
          systemctl stop docker.service 2>/dev/null || true
          shed_level=2
          breaches_page=0; sleep "$BACKOFF"

        # ── Crit-level shed: stop non-tier1 only ─────────────────────────
        elif [ "$breaches_crit" -ge "$NEED" ] && [ "$shed_level" -lt 1 ]; then
          logger -t load-shedder "SHED-CRIT: memPSI=''${MEM} — shedding non-tier1 containers"
          if shed_non_tier1; then
            ntfy_send 4 "health_resources" "LOAD SHED — non-tier1 stopped" "memPSI=''${MEM}%% ≥ $MEM_PSI_CRIT%% × $NEED. Stopped non-tier1. Tier1 [${tier1List}] still running. Recover: build.sh ship."
            : > /run/load-shedder.fired 2>/dev/null || true
            shed_level=1
          else
            # No non-tier1 to stop — escalate immediately to full shed
            logger -t load-shedder "SHED-PAGE (escalated): no non-tier1 containers to shed"
            ntfy_send 5 "health_resources" "LOAD SHED — ALL DOCKER (escalated)" "All running containers are tier-1; stopping everything. memPSI=''${MEM}%%."
            : > /run/load-shedder.fired 2>/dev/null || true
            systemctl stop docker.socket 2>/dev/null || true
            systemctl stop docker.service 2>/dev/null || true
            shed_level=2
          fi
          breaches_crit=0; sleep "$BACKOFF"
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
