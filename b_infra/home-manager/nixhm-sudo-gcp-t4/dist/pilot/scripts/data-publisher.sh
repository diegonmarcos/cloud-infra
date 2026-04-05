#!/bin/sh
# data-publisher — collect VM data JSONs every 5 minutes
# Outputs: /opt/pilot/data/containers.json, journal-errors.json, cloud-data-home-manager.json
# POSIX sh only
set -eu

DATA_DIR="/opt/pilot/data"
mkdir -p "$DATA_DIR"

# Copy cloud-data for dashboard sidebar
if [ -f /opt/cloud-data/cloud-data-home-manager.json ]; then
  cp -f /opt/cloud-data/cloud-data-home-manager.json "$DATA_DIR/cloud-data-home-manager.json"
elif [ -f "$HOME/.config/home-manager/pilot/cloud-data-home-manager.json" ]; then
  cp -f "$HOME/.config/home-manager/pilot/cloud-data-home-manager.json" "$DATA_DIR/cloud-data-home-manager.json"
fi

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
