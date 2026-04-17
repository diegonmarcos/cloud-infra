# Evidence Collector — daily full-capture of container filesystems + journal + runtime state
# Outputs to /var/backups/evidence/<date>/ with manifest.json for diff-based analysis.
# Triggered by Dagu DAG (ops_backup-evidence) or systemd timer as fallback.
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

      echo "[evidence-collector] Starting capture for $HOSTNAME ($DATE)"
      sudo mkdir -p "$EVIDENCE_DIR"
      sudo chown "$(id -u):$(id -g)" "$EVIDENCE_DIR"

      # ── Phase 1: Container filesystem exports (parallel, backgrounded) ──
      CONTAINERS=$(docker ps --format '{{.Names}}' 2>/dev/null || true)
      CTR_COUNT=0
      for ctr in $CONTAINERS; do
        docker export "$ctr" 2>/dev/null | gzip > "$EVIDENCE_DIR/$ctr.tar.gz" &
        CTR_COUNT=$((CTR_COUNT + 1))
      done
      # Wait for all exports (max 5 min timeout)
      TIMEOUT=300
      WAITED=0
      while [ "$(jobs -rp | wc -l)" -gt 0 ] && [ "$WAITED" -lt "$TIMEOUT" ]; do
        sleep 5
        WAITED=$((WAITED + 5))
      done
      # Kill any stragglers
      jobs -rp | xargs kill 2>/dev/null || true
      wait 2>/dev/null || true
      echo "[evidence-collector] Exported $CTR_COUNT containers"

      # ── Phase 2: VM system paths ───────────────────────────────────────
      tar czf "$EVIDENCE_DIR/vm-system.tar.gz" \
        /etc /tmp /var/tmp /root /home \
        --exclude='/home/*/.nix-*' \
        --exclude='/home/*/.cache' \
        --exclude='/tmp/.X11*' \
        2>/dev/null || true
      echo "[evidence-collector] Captured VM system paths"

      # ── Phase 3: Generate manifest (SHA256 of every exported file) ─────
      MANIFEST="$EVIDENCE_DIR/manifest.json"
      echo "{" > "$MANIFEST"
      echo "  \"vm\": \"$HOSTNAME\"," >> "$MANIFEST"
      echo "  \"date\": \"$DATE\"," >> "$MANIFEST"
      echo "  \"containers\": {" >> "$MANIFEST"

      FIRST_CTR=true
      for tarball in "$EVIDENCE_DIR"/*.tar.gz; do
        [ -f "$tarball" ] || continue
        BASENAME=$(basename "$tarball" .tar.gz)
        [ "$BASENAME" = "vm-system" ] && continue

        [ "$FIRST_CTR" = true ] && FIRST_CTR=false || echo "," >> "$MANIFEST"
        echo "    \"$BASENAME\": {" >> "$MANIFEST"
        echo "      \"archive_sha256\": \"$(sha256sum "$tarball" | awk '{print $1}')\"," >> "$MANIFEST"
        echo "      \"archive_size\": $(stat -c%s "$tarball" 2>/dev/null || stat -f%z "$tarball" 2>/dev/null || echo 0)," >> "$MANIFEST"
        echo "      \"image_id\": \"$(docker inspect --format '{{.Image}}' "$BASENAME" 2>/dev/null || echo 'unknown')\"" >> "$MANIFEST"
        echo -n "    }" >> "$MANIFEST"
      done

      echo "" >> "$MANIFEST"
      echo "  }," >> "$MANIFEST"

      # VM system archive hash
      if [ -f "$EVIDENCE_DIR/vm-system.tar.gz" ]; then
        echo "  \"system_sha256\": \"$(sha256sum "$EVIDENCE_DIR/vm-system.tar.gz" | awk '{print $1}')\"," >> "$MANIFEST"
        echo "  \"system_size\": $(stat -c%s "$EVIDENCE_DIR/vm-system.tar.gz" 2>/dev/null || stat -f%z "$EVIDENCE_DIR/vm-system.tar.gz" 2>/dev/null || echo 0)" >> "$MANIFEST"
      fi
      echo "}" >> "$MANIFEST"
      echo "[evidence-collector] Generated manifest.json"

      # ── Phase 4: Journal export (last 24h) ─────────────────────────────
      journalctl --since=-1d -o json 2>/dev/null | gzip > "$EVIDENCE_DIR/journal-24h.json.gz" || true
      echo "[evidence-collector] Captured journal (24h)"

      # ── Phase 5: Runtime state snapshot ────────────────────────────────
      docker inspect $(docker ps -q 2>/dev/null) > "$EVIDENCE_DIR/docker-inspect.json" 2>/dev/null || echo "[]" > "$EVIDENCE_DIR/docker-inspect.json"
      ps auxww --no-headers 2>/dev/null | awk '{print $1,$2,$3,$4,$11}' > "$EVIDENCE_DIR/processes.txt" || true
      ss -tnp 2>/dev/null > "$EVIDENCE_DIR/connections.txt" || true
      docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}' 2>/dev/null > "$EVIDENCE_DIR/container-stats.txt" || true
      echo "[evidence-collector] Captured runtime state"

      # ── Phase 6: Diff vs yesterday (if exists) ────────────────────────
      if [ -f "$PREV_DIR/manifest.json" ]; then
        DIFF_FILE="$EVIDENCE_DIR/diff.json"
        echo "{" > "$DIFF_FILE"
        echo "  \"baseline\": \"$(basename "$PREV_DIR")\"," >> "$DIFF_FILE"
        echo "  \"current\": \"$DATE\"," >> "$DIFF_FILE"

        # Compare container archives by SHA256
        echo "  \"containers\": {" >> "$DIFF_FILE"
        FIRST=true
        for key in $(jq -r '.containers | keys[]' "$EVIDENCE_DIR/manifest.json" 2>/dev/null); do
          NEW_HASH=$(jq -r ".containers.\"$key\".archive_sha256 // \"new\"" "$EVIDENCE_DIR/manifest.json")
          OLD_HASH=$(jq -r ".containers.\"$key\".archive_sha256 // \"missing\"" "$PREV_DIR/manifest.json")
          STATUS="unchanged"
          [ "$OLD_HASH" = "missing" ] && STATUS="new"
          [ "$OLD_HASH" != "$NEW_HASH" ] && [ "$OLD_HASH" != "missing" ] && STATUS="modified"
          [ "$FIRST" = true ] && FIRST=false || echo "," >> "$DIFF_FILE"
          echo -n "    \"$key\": \"$STATUS\"" >> "$DIFF_FILE"
        done
        # Check for deleted containers (in old but not new)
        for key in $(jq -r '.containers | keys[]' "$PREV_DIR/manifest.json" 2>/dev/null); do
          EXISTS=$(jq -r ".containers.\"$key\" // \"gone\"" "$EVIDENCE_DIR/manifest.json")
          if [ "$EXISTS" = "gone" ]; then
            echo "," >> "$DIFF_FILE"
            echo -n "    \"$key\": \"deleted\"" >> "$DIFF_FILE"
          fi
        done
        echo "" >> "$DIFF_FILE"
        echo "  }," >> "$DIFF_FILE"

        # System archive diff
        NEW_SYS=$(jq -r '.system_sha256 // "none"' "$EVIDENCE_DIR/manifest.json")
        OLD_SYS=$(jq -r '.system_sha256 // "none"' "$PREV_DIR/manifest.json")
        if [ "$NEW_SYS" = "$OLD_SYS" ]; then
          echo "  \"system\": \"unchanged\"" >> "$DIFF_FILE"
        else
          echo "  \"system\": \"modified\"" >> "$DIFF_FILE"
        fi
        echo "}" >> "$DIFF_FILE"
        echo "[evidence-collector] Generated diff.json (vs $(basename "$PREV_DIR"))"
      else
        echo "[evidence-collector] No previous snapshot — skipping diff"
      fi

      # ── Phase 7: Upload to S3 via rustic (if configured) ──────────────
      if command -v rustic >/dev/null 2>&1 && [ -n "''${RUSTIC_REPO:-}" ]; then
        export AWS_ACCESS_KEY_ID="''${AWS_ACCESS_KEY_ID:-}"
        export AWS_SECRET_ACCESS_KEY="''${AWS_SECRET_ACCESS_KEY:-}"
        export RUSTIC_PASSWORD="''${RUSTIC_PASSWORD:-}"
        rustic init 2>/dev/null || true
        rustic backup "$EVIDENCE_DIR" \
          --tag evidence --tag "$HOSTNAME" --tag "$DATE" && \
          echo "[evidence-collector] Uploaded to S3" || \
          echo "[evidence-collector] S3 upload failed (will retry via DAG)"
      else
        echo "[evidence-collector] Rustic not configured — local capture only"
      fi

      # ── Cleanup old evidence (keep 3 days locally) ────────────────────
      find /var/backups/evidence -maxdepth 1 -mindepth 1 -type d -mtime +3 -exec rm -rf {} \; 2>/dev/null || true

      TOTAL_SIZE=$(du -sh "$EVIDENCE_DIR" 2>/dev/null | awk '{print $1}' || echo "?")
      echo "[evidence-collector] Done: $EVIDENCE_DIR ($TOTAL_SIZE)"
    '';
  };

  home.file.".local/share/system-protection/evidence-collector.service".text = ''
    [Unit]
    Description=Evidence Collector — daily full-capture for security analysis
    After=network.target docker.service
    [Service]
    Type=oneshot
    ExecStart=/opt/scripts/evidence-collector.sh
    User=root
    TimeoutStartSec=600
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

    echo "[evidence-collector] deployed: timer=daily@02:30"
    ) || echo "[evidence-collector] FAILED — activation continues"
  '';
}
