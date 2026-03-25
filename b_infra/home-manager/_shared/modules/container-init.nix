# Container Init — generic sequential startup for ALL VMs
#
# Problem: starting all containers at once causes OOM on 1GB VMs.
# Solution: systemd service that starts each compose project one at a time.
#
# Zero parameters — fully generic. Auto-discovers all compose projects
# in /opt/containers/ and any extra dirs in /opt/*/docker-compose.yml.
#
# Deploys:
#   - /opt/scripts/container-init.sh
#   - /etc/systemd/system/container-init.service
#
# Imported via shared-all.nix — all VMs get this automatically.
{ config, pkgs, lib, ... }:

{
  home.file.".local/share/container-init/container-init.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      # Container Init — sequential startup for all VMs
      # Managed by home-manager (container-init.nix) — do not edit
      set -uo pipefail

      LOG_TAG="container-init"
      CONTAINERS_DIR="/opt/containers"
      DELAY=2

      log() { echo "[$LOG_TAG] $(date '+%H:%M:%S') $*"; }

      # ── Phase 0: Ensure Docker is running ──────────────────────────────
      if ! systemctl is-active docker >/dev/null 2>&1; then
        log "Docker not running — starting..."
        systemctl start docker
        # Wait up to 30s for Docker to be ready
        for i in $(seq 1 30); do
          docker info >/dev/null 2>&1 && break
          sleep 1
        done
        if ! docker info >/dev/null 2>&1; then
          log "FATAL: Docker failed to start after 30s"
          exit 1
        fi
        log "Docker started"
      fi

      # ── Phase 1: Discover compose projects ─────────────────────────────
      # Primary: /opt/containers/*/docker-compose.yml
      # Extra:   /opt/*/docker-compose.yml (e.g. /opt/stalwart)
      PROJECTS=""
      for dir in "$CONTAINERS_DIR"/*/; do
        [ -f "$dir/docker-compose.yml" ] && PROJECTS="$PROJECTS $dir"
      done
      for dir in /opt/*/; do
        [ "$dir" = "$CONTAINERS_DIR/" ] && continue
        [ "$dir" = "/opt/scripts/" ] && continue
        [ "$dir" = "/opt/ssh-keys/" ] && continue
        [ -f "$dir/docker-compose.yml" ] && PROJECTS="$PROJECTS $dir"
      done

      COUNT=$(echo $PROJECTS | wc -w)
      log "Found $COUNT compose projects"

      # ── Phase 2: Sequential startup ────────────────────────────────────
      STARTED=0
      FAILED=0
      for dir in $PROJECTS; do
        svc=$(basename "$dir")
        log "  starting: $svc"
        if (cd "$dir" && docker compose up -d 2>&1); then
          STARTED=$((STARTED + 1))
        else
          log "  WARN: $svc failed to start"
          FAILED=$((FAILED + 1))
        fi
        sleep "$DELAY"
      done

      log "Done — $STARTED started, $FAILED failed (of $COUNT total)"
    '';
  };

  home.file.".local/share/container-init/container-init.service".text = ''
    [Unit]
    Description=Sequential container startup (container-init)
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/opt/scripts/container-init.sh
    TimeoutStartSec=600

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

    # Deploy script
    $SUDO mkdir -p /opt/scripts
    $SUDO cp -f "$SRC/container-init.sh" /opt/scripts/container-init.sh
    $SUDO chmod +x /opt/scripts/container-init.sh

    # Deploy systemd unit (only if changed)
    UNIT_DEST="/etc/systemd/system/container-init.service"
    NEW_UNIT=$(cat "$SRC/container-init.service")
    CURRENT=""
    if $SUDO test -f "$UNIT_DEST"; then
      CURRENT=$($SUDO cat "$UNIT_DEST" 2>/dev/null || true)
    fi

    if [ "$NEW_UNIT" != "$CURRENT" ]; then
      echo "$NEW_UNIT" | $SUDO tee "$UNIT_DEST" > /dev/null
      $SUDO systemctl daemon-reload
      echo "[container-init] systemd unit deployed"
    fi

    $SUDO systemctl enable container-init.service 2>/dev/null || true
    echo "[container-init] deployed: sequential startup on boot"
    ) || echo "[container-init] FAILED — see errors above, activation continues"
  '';
}
# Trigger home-manager deploy - 2026-03-25T02:13:15+01:00
