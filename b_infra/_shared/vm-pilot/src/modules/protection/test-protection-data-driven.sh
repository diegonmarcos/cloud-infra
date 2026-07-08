#!/usr/bin/env bash
# test-protection-data-driven.sh — verify the protection stack is fully data-driven.
#
# Asserts that load-shedder.nix, tier1-apps.nix, watchdog.nix and health-agent.nix
# read their thresholds / tier-1 lists from the consolidated cloud-data
# (config.json native.protection defaults + b_infra/nixhm-sudo-<alias>/build.json
# .protection per-VM overrides) — NOT from hardcoded Nix literals — by evaluating
# each module with a real vmName and grepping the generated script/unit text for
# the expected data-driven values.
#
# Covers PLAN-hardening-2026-07-07 §1B P1-P5 + §3B/§3C.
#
# Run:  bash test-protection-data-driven.sh
# Deps: nix-instantiate (pure eval, no build — safe on any machine incl. termux).
#
# This is a SYNTAX + DATA-FLOW test. The runtime behaviour (actual shed / restart /
# ntfy fire under memory pressure) is covered by the stress-ng GHA harness spec in
# test-tier1-stress.md — never run that here.
set -euo pipefail

MODULES_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # .../src/modules
cd "$MODULES_DIR"

command -v nix-instantiate >/dev/null 2>&1 || {
  echo "SKIP: nix-instantiate not available"; exit 0
}

TEST_NIX="$(mktemp --suffix=.nix -p "$MODULES_DIR")"
trap 'rm -f "$TEST_NIX"' EXIT

cat > "$TEST_NIX" <<'EOF'
let
  lib = import <nixpkgs/lib>;
  pkgs = { gawk = "/gawk-stub"; systemd = "/systemd-stub"; };
  config = {};
  ls = import ./protection/load-shedder.nix { inherit config pkgs lib; ramMB = 1024; vmName = "oci-mail"; };
  t1raw = import ./protection/tier1-apps.nix { inherit config pkgs lib; vmName = "gcp-proxy"; };
  t1emptyRaw = import ./protection/tier1-apps.nix { inherit config pkgs lib; vmName = "oci-apps"; };
  ha = import ./agents/health-agent.nix { inherit config pkgs lib; vmName = "oci-apps"; };
  wd = import ./protection/watchdog.nix { inherit config pkgs lib; ramMB = 1024; vmName = "oci-mail"; };
  t1 = t1raw.content;
  lsText = ls.home.file.".local/share/system-protection/load-shedder.sh".text;
  haText = ha.home.file.".local/share/system-protection/health-agent.sh".text;
  wdText = wd.home.file.".local/share/system-protection/watchdog-petter.service".text;
  has = lib.hasInfix;
in {
  # ── §3C graduated shed + P4 per-VM override (oci-mail warn=30) ──────────
  ls_tier1_maddy   = has ''TIER1_SERVICES="maddy stalwart mail-puller"'' lsText;
  ls_warn_override = has "MEM_PSI_WARN=30" lsText;   # per-VM override wins over default 35
  ls_page_default  = has "MEM_PSI_PAGE=65" lsText;
  # ── §3B tier1 slice reserved memory (gcp-proxy: 5 svc × 48MB = 240M) ────
  t1_gcp_on        = t1raw.condition;               # gcp-proxy has tier1 → module active
  t1_apps_off      = ! t1emptyRaw.condition;        # oci-apps no tier1 → mkIf false
  t1_slice_reserve = has "MemoryMin=240M" (t1.home.file.".local/share/system-protection/tier1.slice".text);
  t1_caddy_list    = has ''TIER1="caddy introspect-proxy authelia hickory-dns wireguard-mesh-ws-tunnel"''
                       (t1.home.file.".local/share/system-protection/tier1-watchdog.sh".text);
  # ── P2 fd thresholds + P3 wg-stale (defaults) ───────────────────────────
  ha_fd_warn       = has "FD_WARN_PCT=70" haText;
  ha_fd_crit       = has "FD_CRIT_PCT=90" haText;
  ha_wg_stale      = has "WG_STALE_SECS=180" haText;
  # ── P4 watchdog disk/docker/lowmem env injection ────────────────────────
  wd_disk_warn     = has "DISK_WARN=80" wdText;
  wd_docker_fail   = has "DOCKER_FAIL_THRESHOLD=120" wdText;
  wd_lowmem_prune  = has "LOW_MEM_PRUNE_MB=50" wdText;
}
EOF

echo "== evaluating protection modules with real vmName =="
RESULT="$(nix-instantiate --eval --strict --json "$TEST_NIX")"
echo "$RESULT" | tr ',' '\n' | sed 's/[{}"]//g'

# Fail if any assertion is false.
if echo "$RESULT" | grep -q ':false'; then
  echo "FAIL: one or more data-driven assertions were false (see above)"
  exit 1
fi
echo "PASS: all protection thresholds + tier-1 lists are data-driven from consolidated cloud-data"
