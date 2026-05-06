#!/bin/bash
# test-heavy-load-guardrails.sh — Stress test SSH/WG protection
#
# Runs FROM YOUR LOCAL MACHINE against a target VM.
# Creates extreme load OUTSIDE container-init (raw processes)
# then checks if SSH remains responsive.
#
# Usage: ./test-heavy-load-guardrails.sh <vm-alias> [ssh-port]
# Example: ./test-heavy-load-guardrails.sh gcp-proxy 2200

set -uo pipefail

VM="${1:?Usage: test-heavy-load-guardrails.sh <vm-alias> [ssh-port]}"
PORT="${2:-22}"
ROUNDS=15
INTERVAL=3
PASS=0
FAIL=0
SLOW=0

echo "═══════════════════════════════════════════════════════════"
echo "  HEAVY LOAD GUARDRAILS TEST — $VM (port $PORT)"
echo "═══════════════════════════════════════════════════════════"
echo ""

# ── Phase 1: Baseline (no load) ──────────────────────────────────────
echo "── Phase 1: Baseline (no load) ──"
for i in 1 2 3; do
  start=$(date +%s%3N)
  timeout 5 ssh -p "$PORT" "$VM" 'echo ok' >/dev/null 2>&1
  ms=$(( $(date +%s%3N) - start ))
  echo "  [baseline $i] ${ms}ms"
done

# ── Phase 2: Start stress (CPU + IO + MEM — outside any cgroup) ──────
echo ""
echo "── Phase 2: Starting stress (CPU saturation + IO flood + memory pressure) ──"
ssh -p "$PORT" "$VM" 'nohup bash -c "
  # CPU: 4 cores saturated
  for i in 1 2 3 4; do dd if=/dev/zero of=/dev/null bs=1M & done
  # IO: disk flood
  dd if=/dev/urandom of=/tmp/stress_io bs=1M count=500 conv=fdatasync &
  # MEM: allocate and touch pages
  head -c 300M /dev/urandom > /tmp/stress_mem &
  echo \$! > /tmp/stress_pids
" &>/dev/null &' 2>/dev/null

sleep 2

# ── Phase 3: SSH responsiveness under stress ─────────────────────────
echo ""
echo "── Phase 3: SSH responsiveness under heavy load ($ROUNDS rounds, ${INTERVAL}s interval) ──"
echo ""
printf "%-6s %-8s %-10s %-12s %-10s %s\n" "Round" "Time" "Status" "Load" "FreeMB" "OOMadj"
echo "────── ──────── ────────── ──────────── ────────── ──────"

for i in $(seq 1 $ROUNDS); do
  start=$(date +%s%3N)
  result=$(timeout 8 ssh -p "$PORT" "$VM" '
    load=$(cut -d" " -f1 /proc/loadavg)
    mem=$(free -m | awk "/Mem:/{print \$4}")
    oom=$(cat /proc/$(pgrep -o sshd)/oom_score_adj 2>/dev/null || echo "?")
    echo "$load $mem $oom"
  ' 2>&1)
  rc=$?
  ms=$(( $(date +%s%3N) - start ))

  if [ $rc -eq 0 ] && [ -n "$result" ]; then
    load=$(echo "$result" | awk '{print $1}')
    mem=$(echo "$result" | awk '{print $2}')
    oom=$(echo "$result" | awk '{print $3}')
    if [ "$ms" -gt 5000 ]; then
      status="SLOW"
      SLOW=$((SLOW + 1))
    else
      status="OK"
    fi
    PASS=$((PASS + 1))
    printf "%-6s %-8s %-10s %-12s %-10s %s\n" "[$i]" "${ms}ms" "$status" "$load" "${mem}MB" "$oom"
  else
    FAIL=$((FAIL + 1))
    printf "%-6s %-8s %-10s %-12s %-10s %s\n" "[$i]" "${ms}ms" "TIMEOUT" "?" "?" "?"
  fi

  sleep "$INTERVAL"
done

# ── Phase 4: Kill stress and WG test ─────────────────────────────────
echo ""
echo "── Phase 4: Cleanup + WG connectivity ──"
ssh -p "$PORT" "$VM" 'sudo killall -9 dd 2>/dev/null; rm -f /tmp/stress_io /tmp/stress_mem /tmp/stress_pids; echo "stress killed"' 2>/dev/null
sleep 2

# Test WG connectivity (ping through mesh)
echo -n "  WG mesh ping: "
wg_result=$(timeout 5 ssh -p "$PORT" "$VM" 'ping -c 1 -W 2 10.0.0.6 2>&1 | grep -o "time=.*"' 2>&1)
if [ -n "$wg_result" ]; then
  echo "OK ($wg_result)"
else
  echo "FAILED"
  FAIL=$((FAIL + 1))
fi

# ── Report ────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  RESULTS: $PASS ok, $SLOW slow (>5s), $FAIL failed"
echo "═══════════════════════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
  echo "  ❌ PROTECTION FAILED — SSH/WG not bulletproof"
  exit 1
elif [ "$SLOW" -gt 3 ]; then
  echo "  ⚠️  DEGRADED — SSH survived but too many slow responses"
  exit 2
else
  echo "  ✅ BULLETPROOF — SSH responsive under extreme load"
  exit 0
fi
