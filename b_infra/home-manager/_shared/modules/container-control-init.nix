# Container Init — owns Docker lifecycle + sequential container startup
#
# Docker is DISABLED from systemd auto-start.
# This service is the ONLY way Docker and containers start.
#
# Phase 0: Start Docker daemon (with health gate)
# Phase 1: Sequential compose up (one project at a time, OOM-safe)
# Phase 2: Health verification (check every container, retry unhealthy)
# Phase 3: Report to ntfy (final status)
#
# On failure: graceful handling, no crash loops, ntfy alert.
#
# Deploys:
#   - /opt/scripts/container-init.sh
#   - /etc/systemd/system/container-init.service
#
# Imported via shared-all.nix — all VMs get this automatically.
{ config, pkgs, lib, ... }:

let
  cloudData = builtins.fromJSON (builtins.readFile ./cloud-data-home-manager.json);
  ntfyUrl = "${cloudData.monitoring.ntfy_base}/container-init";
  dockerStartTimeout = 60;
  healthCheckTimeout = 120;
  healthCheckInterval = 5;
  startDelay = 3;
  dockerdBin = "${pkgs.docker}/bin/dockerd";
in {
  # ── Docker unit file — NO [Install], container-init starts it ───────
  home.file.".local/share/container-init/docker.service".text = ''
    [Unit]
    Description=Docker Application Container Engine (nix)
    After=network-online.target

    [Service]
    Type=notify
    ExecStart=${dockerdBin}
    ExecReload=/bin/kill -s HUP $MAINPID
    Restart=always
    RestartSec=5
    LimitNOFILE=infinity
    LimitNPROC=infinity
    LimitCORE=infinity
    CPUQuota=80%
    Delegate=yes
    KillMode=process
  '';

  # ── Docker daemon config — iptables + DNS (single owner of daemon.json) ─
  home.file.".local/share/container-init/daemon.json".text = builtins.toJSON {
    iptables = false;
    ip6tables = false;
    dns = [ cloudData.dns.primary cloudData.dns.fallback ];
  };
  home.file.".local/share/container-init/container-init.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      # Container Init — Docker lifecycle + sequential container startup
      # Managed by home-manager (container-init.nix) — do not edit
      set -uo pipefail

      # Ensure nix binaries (docker, docker-compose) are in PATH for systemd
      for p in /home/*/nix-profile/bin /home/*/.nix-profile/bin /nix/var/nix/profiles/default/bin; do
        [ -d "$p" ] && export PATH="$p:$PATH"
      done

      HOSTNAME=$(hostname -s 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "unknown")
      LOG_TAG="container-init"
      LOG_FILE="/var/log/container-init.log"
      BOOT_JSON="/var/log/container-init-boot.json"
      CONTAINERS_DIR="/opt/containers"
      NTFY_URL="${ntfyUrl}"
      DOCKER_TIMEOUT=${toString dockerStartTimeout}
      HEALTH_TIMEOUT=${toString healthCheckTimeout}
      HEALTH_INTERVAL=${toString healthCheckInterval}
      START_DELAY=${toString startDelay}
      BOOT_START=$(date +%s%3N)
      _LAST_STEP=$BOOT_START

      # ── Perf + Logging (flush every line) ─────────────────────────────
      log() {
        local now=$(date +%s%3N)
        local elapsed=$(( now - BOOT_START ))
        local step_ms=$(( now - _LAST_STEP ))
        _LAST_STEP=$now
        local msg="[$LOG_TAG] +''${elapsed}ms (+''${step_ms}ms) $*"
        echo "$msg" >&2
        echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
      }

      ntfy() {
        local title="$1" body="$2" priority="''${3:-default}" tags="''${4:-whale}"
        curl -sf -X POST "$NTFY_URL" \
          -H "Title: [$HOSTNAME] $title" \
          -H "Priority: $priority" \
          -H "Tags: $tags" \
          -d "$body" >/dev/null 2>&1 || true
      }

      elapsed() { echo $(( $(date +%s) - BOOT_START )); }

      # ── Phase 0: Docker daemon startup ────────────────────────────────
      log "═══ PHASE 0: Docker daemon ═══"
      DOCKER_OK=false

      if docker info >/dev/null 2>&1; then
        log "Docker already running"
        DOCKER_OK=true
      else
        log "Starting Docker daemon..."
        systemctl start docker 2>&1 | while read -r line; do log "  docker: $line"; done

        # Health gate: wait for Docker to respond
        for i in $(seq 1 "$DOCKER_TIMEOUT"); do
          if docker info >/dev/null 2>&1; then
            DOCKER_OK=true
            log "Docker healthy after ''${i}s"
            break
          fi
          # Check if Docker process died
          if ! systemctl is-active docker >/dev/null 2>&1; then
            log "FATAL: Docker process died during startup"
            break
          fi
          log "  waiting for dockerd... (''${i}/''${DOCKER_TIMEOUT}s) mem=$(free -m 2>/dev/null | awk '/Mem:/{print $4}')MB free"
          sleep 1
        done
      fi

      if [ "$DOCKER_OK" = false ]; then
        log "FATAL: Docker failed to become healthy after ''${DOCKER_TIMEOUT}s"
        ntfy "Docker FAILED" "Docker daemon did not start on $HOSTNAME after ''${DOCKER_TIMEOUT}s. Manual intervention required." "urgent" "rotating_light"
        # Don't exit — log the failure and let systemd handle restart policy
        echo '{"boot":"'$(date -Iseconds)'","docker":"failed","containers":[],"total_s":'$(elapsed)'}' > "$BOOT_JSON" 2>/dev/null || true
        exit 1
      fi

      DOCKER_ELAPSED=$(elapsed)
      log "Docker ready (''${DOCKER_ELAPSED}s)"

      # ── Phase 1: Discover compose projects ────────────────────────────
      log "═══ PHASE 1: Discover compose projects ═══"
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

      PROJECT_COUNT=$(echo $PROJECTS | wc -w)
      log "Found $PROJECT_COUNT compose projects"

      # ── Phase 2: Sequential startup ───────────────────────────────────
      log "═══ PHASE 2: Sequential startup ═══"
      STARTED=0
      FAILED=0
      BOOT_RESULTS=""

      for dir in $PROJECTS; do
        svc=$(basename "$dir")
        svc_start=$(date +%s)
        log "  [$svc] starting..."

        if (cd "$dir" && docker compose up -d --no-build 2>&1 | while read -r line; do log "    $line"; done); then
          svc_ms=$(( ($(date +%s) - svc_start) * 1000 ))
          log "  [$svc] started (''${svc_ms}ms)"
          STARTED=$((STARTED + 1))
          BOOT_RESULTS="$BOOT_RESULTS{\"name\":\"$svc\",\"ms\":$svc_ms,\"ok\":true},"
        else
          svc_ms=$(( ($(date +%s) - svc_start) * 1000 ))
          log "  [$svc] FAILED to start"
          FAILED=$((FAILED + 1))
          BOOT_RESULTS="$BOOT_RESULTS{\"name\":\"$svc\",\"ms\":$svc_ms,\"ok\":false},"
        fi

        sleep "$START_DELAY"
      done

      STARTUP_ELAPSED=$(elapsed)
      log "Startup complete: $STARTED ok, $FAILED failed (''${STARTUP_ELAPSED}s)"

      # ── Phase 3: Health verification ──────────────────────────────────
      log "═══ PHASE 3: Health verification ═══"
      HEALTH_START=$(date +%s)
      UNHEALTHY=""
      HEALTHY_COUNT=0
      TOTAL_CONTAINERS=0
      RESTARTED=0

      # Wait a moment for containers to initialize
      sleep 10

      # Check all running containers
      while IFS= read -r container; do
        [ -z "$container" ] && continue
        TOTAL_CONTAINERS=$((TOTAL_CONTAINERS + 1))
        name=$(docker inspect --format='{{.Name}}' "$container" 2>/dev/null | sed 's/^\///')
        has_healthcheck=$(docker inspect --format='{{if .Config.Healthcheck}}yes{{else}}no{{end}}' "$container" 2>/dev/null || echo "no")

        if [ "$has_healthcheck" = "yes" ]; then
          # Container has healthcheck — wait for it
          health="starting"
          waited=0
          while [ "$health" = "starting" ] && [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
            health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "unknown")
            [ "$health" = "starting" ] && sleep "$HEALTH_INTERVAL" && waited=$((waited + HEALTH_INTERVAL))
          done

          if [ "$health" = "healthy" ]; then
            HEALTHY_COUNT=$((HEALTHY_COUNT + 1))
          else
            log "  UNHEALTHY: $name (status: $health) — restarting..."
            docker restart "$container" >/dev/null 2>&1

            # Wait for restart health
            sleep 10
            health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "unknown")
            RESTARTED=$((RESTARTED + 1))

            if [ "$health" = "healthy" ]; then
              log "  [$name] healthy after restart"
              HEALTHY_COUNT=$((HEALTHY_COUNT + 1))
            else
              log "  [$name] STILL UNHEALTHY after restart (status: $health)"
              UNHEALTHY="$UNHEALTHY $name"
            fi
          fi
        else
          # No healthcheck — just check if running
          state=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "unknown")
          if [ "$state" = "running" ]; then
            HEALTHY_COUNT=$((HEALTHY_COUNT + 1))
          else
            log "  NOT RUNNING: $name (state: $state)"
            UNHEALTHY="$UNHEALTHY $name"
          fi
        fi
      done < <(docker ps -q 2>/dev/null)

      HEALTH_ELAPSED=$(( $(date +%s) - HEALTH_START ))
      TOTAL_ELAPSED=$(elapsed)

      log "Health check: $HEALTHY_COUNT/$TOTAL_CONTAINERS healthy, $RESTARTED restarted (''${HEALTH_ELAPSED}s)"

      # ── Phase 4: Report ───────────────────────────────────────────────
      log "═══ PHASE 4: Report ═══"

      # Write boot metrics JSON
      cat > "$BOOT_JSON" 2>/dev/null <<BOOT_EOF || true
      {"boot":"$(date -Iseconds)","hostname":"$HOSTNAME","docker_s":$DOCKER_ELAPSED,"projects":$PROJECT_COUNT,"started":$STARTED,"failed":$FAILED,"containers":$TOTAL_CONTAINERS,"healthy":$HEALTHY_COUNT,"restarted":$RESTARTED,"total_s":$TOTAL_ELAPSED,"containers_detail":[''${BOOT_RESULTS%,}]}
      BOOT_EOF

      # ntfy report
      if [ -n "$UNHEALTHY" ]; then
        log "UNHEALTHY containers:$UNHEALTHY"
        ntfy "Boot: $STARTED/$PROJECT_COUNT projects, UNHEALTHY:$UNHEALTHY" \
          "Docker: ''${DOCKER_ELAPSED}s | Projects: $STARTED ok, $FAILED fail | Containers: $HEALTHY_COUNT/$TOTAL_CONTAINERS healthy | Restarted: $RESTARTED | Unhealthy:$UNHEALTHY | Total: ''${TOTAL_ELAPSED}s" \
          "high" "warning"
      elif [ "$FAILED" -gt 0 ]; then
        ntfy "Boot: $STARTED/$PROJECT_COUNT projects ($FAILED failed)" \
          "Docker: ''${DOCKER_ELAPSED}s | Projects: $STARTED ok, $FAILED fail | Containers: $HEALTHY_COUNT/$TOTAL_CONTAINERS healthy | Total: ''${TOTAL_ELAPSED}s" \
          "high" "warning"
      else
        ntfy "Boot OK: $PROJECT_COUNT projects, $TOTAL_CONTAINERS containers" \
          "Docker: ''${DOCKER_ELAPSED}s | Projects: $STARTED/$PROJECT_COUNT | Containers: $HEALTHY_COUNT/$TOTAL_CONTAINERS healthy | Total: ''${TOTAL_ELAPSED}s" \
          "default" "white_check_mark"
      fi

      log "═══ CONTAINER INIT COMPLETE (''${TOTAL_ELAPSED}s) ═══"
    '';
  };

  # systemd unit — Docker is NOT required (we start it ourselves)
  home.file.".local/share/container-init/container-init.service".text = ''
    [Unit]
    Description=Container Init — Docker + sequential container startup
    After=network-online.target firewall.service earlyoom.service disk-swap.service zram-setup.service
    Wants=network-online.target

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/opt/scripts/container-init.sh
    TimeoutStartSec=900
    StandardOutput=journal+console
    StandardError=journal+console
    Environment=PYTHONUNBUFFERED=1

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

    # Deploy docker.service unit (NO [Install] — container-init starts it)
    DOCKER_UNIT="$SRC/docker.service"
    DOCKER_DEST="/etc/systemd/system/docker.service"
    DNEW=$(cat "$DOCKER_UNIT")
    DOLD=$($SUDO cat "$DOCKER_DEST" 2>/dev/null || true)
    if [ "$DNEW" != "$DOLD" ]; then
      echo "$DNEW" | $SUDO tee "$DOCKER_DEST" > /dev/null
      echo "[container-init] docker.service deployed"
    fi

    # Deploy daemon.json
    DAEMON_SRC="$SRC/daemon.json"
    DAEMON_DEST="/etc/docker/daemon.json"
    $SUDO mkdir -p /etc/docker
    DJNEW=$(cat "$DAEMON_SRC")
    DJOLD=$($SUDO cat "$DAEMON_DEST" 2>/dev/null || true)
    if [ "$DJNEW" != "$DJOLD" ]; then
      echo "$DJNEW" | $SUDO tee "$DAEMON_DEST" > /dev/null
      echo "[container-init] daemon.json deployed"
    fi

    # Disable docker from systemd auto-start — container-init owns it
    $SUDO systemctl disable docker.service 2>/dev/null || true
    $SUDO systemctl daemon-reload

    $SUDO systemctl enable container-init.service 2>/dev/null || true
    echo "[container-init] deployed: Docker + sequential startup on boot"
    ) || echo "[container-init] FAILED — see errors above, activation continues"
  '';
}
