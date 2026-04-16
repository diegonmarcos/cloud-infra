#!/bin/sh
# data-publisher — collect VM data JSONs every 5 minutes
# Outputs: /opt/pilot/data/containers.json, journal-errors.json, cloud-data-home-manager.json
# POSIX sh only
set -eu

DATA_DIR="/opt/pilot/data"
mkdir -p "$DATA_DIR"

# Copy cloud-data for dashboard sidebar
# Script runs as root — check all known paths for the HM-deployed cloud-data
HM_JSON=""
for p in \
  /opt/cloud-data/cloud-data-home-manager.json \
  /home/ubuntu/.config/home-manager/pilot/cloud-data-home-manager.json \
  /home/diego/.config/home-manager/pilot/cloud-data-home-manager.json \
  "$HOME/.config/home-manager/pilot/cloud-data-home-manager.json"; do
  [ -f "$p" ] && HM_JSON="$p" && break
done
[ -n "$HM_JSON" ] && cp -f "$HM_JSON" "$DATA_DIR/cloud-data-home-manager.json"

# Containers JSON
if command -v docker >/dev/null 2>&1; then
  docker ps -a --format '{"name":"{{.Names}}","status":"{{.Status}}","image":"{{.Image}}","ports":"{{.Ports}}"}' 2>/dev/null \
    | sed '1s/^/[/; $!s/$/,/; $s/$/]/' > "$DATA_DIR/containers.json" 2>/dev/null || echo "[]" > "$DATA_DIR/containers.json"
else
  echo "[]" > "$DATA_DIR/containers.json"
fi

# Journal errors (last 100)
journalctl -p err --no-hostname -o json -n 100 2>/dev/null \
  | sed '1s/^/[/; $!s/$/,/; $s/$/]/' > "$DATA_DIR/journal-errors.json" 2>/dev/null || echo "[]" > "$DATA_DIR/journal-errors.json"

echo "[data-publisher] Updated $(date -u +%Y-%m-%dT%H:%M:%SZ)"
