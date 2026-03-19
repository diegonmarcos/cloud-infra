# Container Init — sequential startup + cleanup of migrated containers
#
# Problem: on 1GB VMs, starting all containers at once causes OOM.
# Solution: systemd service that starts each compose project one at a time.
#
# Also removes stale containers from services that were migrated to other VMs.
#
# Deploys:
#   - /opt/scripts/container-init.sh
#   - /etc/systemd/system/container-init.service
#
# Usage in VM config:
#   (import ./modules/container-init.nix {
#     inherit config pkgs lib;
#     staleContainers = [ "syslog-central" "siem-api" "alerts-api" "dozzle" "fluent-bit" ];
#   })
#
{ config, pkgs, lib, staleContainers ? [], ... }:

let
  staleList = lib.concatStringsSep " " staleContainers;

  staleDirs = lib.concatStringsSep " " [
    "sauron-central"
    "alerts-api"
    "dozzle"
    "fluent-bit"
  ];
in {
  home.file.".local/share/container-init/container-init.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      # Container Init — sequential startup for low-memory VMs
      # Managed by home-manager (container-init.nix) — do not edit
      set -euo pipefail

      CONTAINERS_DIR="/opt/containers"
      LOG_TAG="container-init"

      log() { echo "[$LOG_TAG] $*"; }

      # ── Phase 1: Remove stale containers (migrated to other VMs) ──
      STALE="${staleList}"
      if [ -n "$STALE" ]; then
        log "Removing stale containers: $STALE"
        for name in $STALE; do
          if docker inspect "$name" >/dev/null 2>&1; then
            docker stop "$name" 2>/dev/null || true
            docker rm -f "$name" 2>/dev/null || true
            log "  removed: $name"
          fi
        done
      fi

      # Remove stale compose directories
      STALE_DIRS="${staleDirs}"
      if [ -n "$STALE_DIRS" ]; then
        for dir in $STALE_DIRS; do
          if [ -d "$CONTAINERS_DIR/$dir" ]; then
            log "  removing stale dir: $CONTAINERS_DIR/$dir"
            rm -rf "$CONTAINERS_DIR/$dir"
          fi
        done
      fi

      # ── Phase 2: Sequential container startup ──
      log "Starting containers sequentially..."

      # Priority order: core infra first, then services
      PRIORITY_ORDER="hickory-dns caddy authelia vaultwarden ntfy redis postlite"

      started=""
      for svc in $PRIORITY_ORDER; do
        compose="$CONTAINERS_DIR/$svc/docker-compose.yml"
        if [ -f "$compose" ]; then
          log "  starting: $svc"
          (cd "$CONTAINERS_DIR/$svc" && docker compose up -d 2>&1) || log "  WARN: $svc failed"
          started="$started $svc"
          sleep 2
        fi
      done

      # Start remaining services (not in priority list)
      for dir in "$CONTAINERS_DIR"/*/; do
        [ ! -f "$dir/docker-compose.yml" ] && continue
        svc=$(basename "$dir")
        case " $started " in
          *" $svc "*) continue ;;  # already started
        esac
        log "  starting: $svc"
        (cd "$dir" && docker compose up -d 2>&1) || log "  WARN: $svc failed"
        sleep 2
      done

      log "Done — all containers started sequentially"
    '';
  };

  home.file.".local/share/container-init/container-init.service".text = ''
    [Unit]
    Description=Sequential container startup (container-init)
    After=docker.service network-online.target
    Wants=docker.service network-online.target

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/opt/scripts/container-init.sh
    TimeoutStartSec=300

    [Install]
    WantedBy=multi-user.target
  '';

  # ─── Activation: deploy to system locations with sudo ──────────────────

  home.activation.installContainerInit = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    trap 'echo "[container-init] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    if [ -z "$SUDO" ]; then
      echo "[container-init] WARNING: sudo not found — skipping"
      exit 0
    fi

    SRC="$HOME/.local/share/container-init"

    $SUDO mkdir -p /opt/scripts
    $SUDO cp -f "$SRC/container-init.sh" /opt/scripts/container-init.sh
    $SUDO chmod +x /opt/scripts/container-init.sh
    $SUDO cp -f "$SRC/container-init.service" /etc/systemd/system/container-init.service

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable container-init.service 2>/dev/null || true

    echo "[container-init] deployed: sequential startup + stale cleanup"
    ) || echo "[container-init] FAILED — see errors above, activation continues"
  '';
}
