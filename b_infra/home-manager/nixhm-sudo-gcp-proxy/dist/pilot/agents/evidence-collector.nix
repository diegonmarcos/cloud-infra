# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : b_infra/home-manager/nixhm-sudo-gcp-proxy/src/pilot/agents/evidence-collector.nix
# ║   Engine : 1_workflows/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Evidence Collector — LIGHTWEIGHT daily metadata capture.
#
# Produces /var/backups/evidence/<date>/ containing ONLY the files
# cloud-sec-data-report consumes (see cloud-data-sec-scan.json → evidence_files):
#
#   manifest.json           — hostname + per-container image_id / ports / labels
#   diff.json               — vs. yesterday (new / modified / removed containers)
#   journal-24h.json.gz     — last 24h journal (compressed)
#   docker-inspect.json     — full docker inspect output for running containers
#   processes.txt           — ps aux snapshot
#   connections.txt         — ss -tnp snapshot
#
# Previous versions ran `docker export $ctr | gzip` per container and tarred
# /etc /tmp /var /root /home — heavy CPU+IO, unsuitable for 1 GB VMs.
# That was dropped on 2026-04-20. Sec-data now uses evidence files only,
# never falls back to `docker cp` (phases.docker_cp_fallback_enabled=false).
#
# Imported by: default.nix
#
{ config, pkgs, lib, ... }:
{
  home.file.".local/share/system-protection/evidence-collector.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      set -uo pipefail
      DATE=$(date +%Y-%m-%d)
      EVIDENCE_DIR="/var/backups/evidence/$DATE"
      PREV_DIR="/var/backups/evidence/$(date -d 'yesterday' +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d 2>/dev/null || echo 'none')"
      HOSTNAME=$(hostname -s 2>/dev/null || echo "unknown")

      echo "[evidence-collector] Starting lightweight capture for $HOSTNAME ($DATE)"
      sudo mkdir -p "$EVIDENCE_DIR"
      sudo chown "$(id -u):$(id -g)" "$EVIDENCE_DIR"

      # ── Phase 1: Container metadata manifest ───────────────────────────
      # No docker export. Only image_id + ports + labels — tens of KB total.
      CONTAINERS=$(docker ps --format '{{.Names}}' 2>/dev/null || true)
      MANIFEST="$EVIDENCE_DIR/manifest.json"
      {
        echo "{"
        echo "  \"vm\": \"$HOSTNAME\","
        echo "  \"date\": \"$DATE\","
        echo "  \"schema\": \"lightweight-v1\","
        echo "  \"containers\": {"
        FIRST_CTR=true
        for ctr in $CONTAINERS; do
          IMAGE_ID=$(docker inspect --format '{{.Image}}' "$ctr" 2>/dev/null || echo "unknown")
          IMAGE_NAME=$(docker inspect --format '{{.Config.Image}}' "$ctr" 2>/dev/null || echo "unknown")
          PORTS=$(docker inspect --format '{{range $p, $conf := .NetworkSettings.Ports}}{{$p}} {{end}}' "$ctr" 2>/dev/null | tr -d '\n' || true)
          STATUS=$(docker inspect --format '{{.State.Status}}' "$ctr" 2>/dev/null || echo "unknown")
          [ "$FIRST_CTR" = true ] && FIRST_CTR=false || echo ","
          echo "    \"$ctr\": {"
          echo "      \"image_id\": \"$IMAGE_ID\","
          echo "      \"image_name\": \"$IMAGE_NAME\","
          echo "      \"status\": \"$STATUS\","
          echo "      \"ports\": \"$PORTS\""
          echo -n "    }"
        done
        echo ""
        echo "  }"
        echo "}"
      } > "$MANIFEST"
      echo "[evidence-collector] manifest.json ($(wc -l < "$MANIFEST") lines)"

      # ── Phase 2: docker inspect (full, for runtime/drift analysis) ─────
      RUNNING_IDS=$(docker ps -q 2>/dev/null)
      if [ -n "$RUNNING_IDS" ]; then
        docker inspect $RUNNING_IDS > "$EVIDENCE_DIR/docker-inspect.json" 2>/dev/null || echo "[]" > "$EVIDENCE_DIR/docker-inspect.json"
      else
        echo "[]" > "$EVIDENCE_DIR/docker-inspect.json"
      fi

      # ── Phase 3: Journal export (last 24h, gzip-compressed) ────────────
      # Single read of journalctl index — no per-container exec, no fs tar.
      journalctl --since=-1d -o json 2>/dev/null | gzip > "$EVIDENCE_DIR/journal-24h.json.gz" || true

      # ── Phase 4: Runtime state (cheap, all local commands) ─────────────
      ps auxww --no-headers 2>/dev/null | awk '{print $1,$2,$3,$4,$11}' > "$EVIDENCE_DIR/processes.txt" || true
      ss -tnp 2>/dev/null > "$EVIDENCE_DIR/connections.txt" || true

      # ── Phase 5: Diff vs yesterday ─────────────────────────────────────
      # Metadata diff only — compare image_id per container name.
      DIFF_FILE="$EVIDENCE_DIR/diff.json"
      if [ -f "$PREV_DIR/manifest.json" ]; then
        {
          echo "{"
          echo "  \"baseline\": \"$(basename "$PREV_DIR")\","
          echo "  \"current\": \"$DATE\","
          echo "  \"containers\": {"
          FIRST=true
          for key in $(jq -r '.containers | keys[]' "$EVIDENCE_DIR/manifest.json" 2>/dev/null); do
            NEW_ID=$(jq -r ".containers.\"$key\".image_id // \"new\"" "$EVIDENCE_DIR/manifest.json")
            OLD_ID=$(jq -r ".containers.\"$key\".image_id // \"missing\"" "$PREV_DIR/manifest.json" 2>/dev/null || echo "missing")
            STATUS="unchanged"
            [ "$OLD_ID" = "missing" ] && STATUS="new"
            [ "$OLD_ID" != "$NEW_ID" ] && [ "$OLD_ID" != "missing" ] && STATUS="modified"
            [ "$FIRST" = true ] && FIRST=false || echo ","
            echo -n "    \"$key\": \"$STATUS\""
          done
          for key in $(jq -r '.containers | keys[]' "$PREV_DIR/manifest.json" 2>/dev/null); do
            EXISTS=$(jq -r ".containers.\"$key\" // \"gone\"" "$EVIDENCE_DIR/manifest.json")
            if [ "$EXISTS" = "gone" ]; then
              echo ","
              echo -n "    \"$key\": \"deleted\""
            fi
          done
          echo ""
          echo "  }"
          echo "}"
        } > "$DIFF_FILE"
      else
        echo "{\"baseline\":null,\"current\":\"$DATE\",\"containers\":{}}" > "$DIFF_FILE"
      fi

      # ── Phase 6: Upload to S3 via rustic (optional, tiny payload) ──────
      if command -v rustic >/dev/null 2>&1 && [ -n "''${RUSTIC_REPO:-}" ]; then
        export AWS_ACCESS_KEY_ID="''${AWS_ACCESS_KEY_ID:-}"
        export AWS_SECRET_ACCESS_KEY="''${AWS_SECRET_ACCESS_KEY:-}"
        export RUSTIC_PASSWORD="''${RUSTIC_PASSWORD:-}"
        rustic init 2>/dev/null || true
        rustic backup "$EVIDENCE_DIR" --tag evidence --tag "$HOSTNAME" --tag "$DATE" \
          && echo "[evidence-collector] Uploaded to S3" \
          || echo "[evidence-collector] S3 upload failed (non-fatal)"
      fi

      # Keep 7 days locally (tiny footprint now — KB per day)
      find /var/backups/evidence -maxdepth 1 -mindepth 1 -type d -mtime +7 -exec rm -rf {} \; 2>/dev/null || true

      TOTAL_SIZE=$(du -sh "$EVIDENCE_DIR" 2>/dev/null | awk '{print $1}' || echo "?")
      echo "[evidence-collector] Done: $EVIDENCE_DIR ($TOTAL_SIZE)"
    '';
  };

  home.file.".local/share/system-protection/evidence-collector.service".text = ''
    [Unit]
    Description=Evidence Collector — lightweight daily metadata capture
    After=network.target docker.service
    [Service]
    Type=oneshot
    ExecStart=/opt/scripts/evidence-collector.sh
    User=root
    TimeoutStartSec=180
    Slice=workload.slice
    Nice=10
    OOMScoreAdjust=200
    [Install]
    WantedBy=multi-user.target
  '';

  home.file.".local/share/system-protection/evidence-collector.timer".text = ''
    [Unit]
    Description=Evidence Collector timer (daily 2:30 AM)
    [Timer]
    OnCalendar=*-*-* 02:30:00
    RandomizedDelaySec=5min
    Persistent=true
    [Install]
    WantedBy=timers.target
  '';

  # ── Activation ────────────────────────────────────────────────────────
  home.activation.installEvidenceCollector = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    trap 'echo "[evidence-collector] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && echo "[evidence-collector] no sudo — skipping" && exit 0

    SRC="$HOME/.local/share/system-protection"

    $SUDO mkdir -p /opt/scripts /var/backups/evidence
    $SUDO cp -f "$SRC/evidence-collector.sh" /opt/scripts/evidence-collector.sh
    $SUDO chmod +x /opt/scripts/evidence-collector.sh
    $SUDO cp -f "$SRC/evidence-collector.service" /etc/systemd/system/evidence-collector.service
    $SUDO cp -f "$SRC/evidence-collector.timer" /etc/systemd/system/evidence-collector.timer

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable evidence-collector.timer 2>/dev/null || true
    $SUDO systemctl start evidence-collector.timer 2>/dev/null || true

    echo "[evidence-collector] deployed: timer=daily@02:30 (lightweight)"
    ) || echo "[evidence-collector] FAILED — activation continues"
  '';
}
