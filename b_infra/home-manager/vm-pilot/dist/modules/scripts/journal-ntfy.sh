#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : src/modules/scripts/journal-ntfy.sh
# ║   Engine : b_infra/home-manager/vm-pilot/build.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# journal-ntfy — publish journal errors to ntfy, rate-limited
# One message per service per 5 minutes to avoid flooding
# POSIX sh only — no bash required
set -eu

NTFY_URL="${NTFY_URL:-https://rss.diegonmarcos.com/health_resources}"
VM=$(hostname -s 2>/dev/null || echo "unknown")
RATE_DIR="/tmp/journal-ntfy-rate"
RATE_SECONDS=300

mkdir -p "$RATE_DIR"

journalctl -p err -f --no-hostname -o short-precise 2>/dev/null | while IFS= read -r line; do
  # Extract unit name (best-effort)
  unit=$(echo "$line" | sed -n 's/.*\[\([^]]*\)\].*/\1/p' | head -1)
  [ -z "$unit" ] && unit="unknown"

  # Rate limit: skip if same unit reported within RATE_SECONDS
  rate_file="$RATE_DIR/$unit"
  if [ -f "$rate_file" ]; then
    last=$(cat "$rate_file" 2>/dev/null || echo 0)
    now=$(date +%s)
    elapsed=$((now - last))
    [ "$elapsed" -lt "$RATE_SECONDS" ] && continue
  fi

  # Publish
  date +%s > "$rate_file"
  curl -sf -X POST "$NTFY_URL" \
    -H "Title: [$VM] $unit" \
    -H "Tags: warning,$VM" \
    -H "Priority: 3" \
    -d "$line" >/dev/null 2>&1 || true
done
