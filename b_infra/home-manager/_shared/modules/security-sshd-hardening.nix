# SSH daemon hardening — drops a config snippet into /etc/ssh/sshd_config.d/
# Fixes 50s+ SSH delays caused by reverse DNS lookups (UseDNS)
{ config, pkgs, lib, ... }:

{
  home.activation.sshdHardening = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    (
    trap 'echo "[sshd-hardening] FAILED at line $LINENO (''${FUNCNAME[0]:-main}): $BASH_COMMAND" >&2' ERR
    SSHD_DROP="/etc/ssh/sshd_config.d/10-hardening.conf"
    SSHD_OLD="/etc/ssh/sshd_config.d/90-hardening.conf"
    SSHD_LOG_PREFIX="[sshd-hardening]"

    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    if [ -z "$SUDO" ]; then
      echo "$SSHD_LOG_PREFIX WARN: sudo not found — skipping sshd hardening"
      exit 0
    fi

    # Clean up old filename
    if $SUDO test -f "$SSHD_OLD"; then
      echo "$SSHD_LOG_PREFIX removing old $SSHD_OLD"
      $SUDO rm -f "$SSHD_OLD"
    fi

    # Allowed SSH source IPs (VM mesh + admin + GHA)
    ALLOWED_IPS="10.0.0.0/24 130.110.251.193 129.151.228.66 82.70.229.129 35.226.147.64 34.173.227.250"

    NEW_CONF="# Managed by home-manager (sshd-hardening.nix) — do not edit
# Anti brute-force
PasswordAuthentication no
PermitRootLogin prohibit-password
MaxAuthTries 3
MaxStartups 3:50:10
LoginGraceTime 20
# Performance
UseDNS no
GSSAPIAuthentication no
# Key-only auth
PubkeyAuthentication yes
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
"

    # Deploy iptables SSH allowlist (port 22 + rescue port)
    # Allow: WG mesh, VM public IPs, then DROP all others on port 22
    IPTABLES_SCRIPT="/opt/scripts/ssh-firewall.sh"
    $SUDO tee "$IPTABLES_SCRIPT" > /dev/null << 'FWEOF'
#!/bin/bash
set -euo pipefail
# Flush old SSH rules (chain SSH_ALLOW)
iptables -D INPUT -p tcp --dport 22 -j SSH_ALLOW 2>/dev/null || true
iptables -D INPUT -p tcp --dport 2200 -j SSH_ALLOW 2>/dev/null || true
iptables -F SSH_ALLOW 2>/dev/null || true
iptables -X SSH_ALLOW 2>/dev/null || true

# Create chain
iptables -N SSH_ALLOW 2>/dev/null || true

# Allow WG mesh
iptables -A SSH_ALLOW -s 10.0.0.0/24 -j ACCEPT
# Allow VM public IPs (inter-VM SSH)
iptables -A SSH_ALLOW -s 130.110.251.193 -j ACCEPT
iptables -A SSH_ALLOW -s 129.151.228.66 -j ACCEPT
iptables -A SSH_ALLOW -s 82.70.229.129 -j ACCEPT
iptables -A SSH_ALLOW -s 35.226.147.64 -j ACCEPT
iptables -A SSH_ALLOW -s 34.173.227.250 -j ACCEPT
# Allow localhost
iptables -A SSH_ALLOW -s 127.0.0.1 -j ACCEPT
# Allow GCP internal (for IAP tunnel + metadata)
iptables -A SSH_ALLOW -s 10.128.0.0/16 -j ACCEPT
iptables -A SSH_ALLOW -s 35.235.240.0/20 -j ACCEPT
# Rate limit everyone else: 3 new connections per minute
iptables -A SSH_ALLOW -m state --state NEW -m recent --set --name SSH
iptables -A SSH_ALLOW -m state --state NEW -m recent --update --seconds 60 --hitcount 4 --name SSH -j DROP
# Accept remaining
iptables -A SSH_ALLOW -j ACCEPT

# Hook into INPUT
iptables -I INPUT -p tcp --dport 22 -j SSH_ALLOW
iptables -I INPUT -p tcp --dport 2200 -j SSH_ALLOW
echo "[ssh-firewall] iptables SSH allowlist active"
FWEOF
    $SUDO chmod +x "$IPTABLES_SCRIPT"
    $SUDO "$IPTABLES_SCRIPT" 2>/dev/null || echo "$SSHD_LOG_PREFIX iptables firewall failed (non-fatal)"

    CURRENT=""
    if $SUDO test -f "$SSHD_DROP"; then
      CURRENT=$($SUDO cat "$SSHD_DROP" 2>/dev/null || true)
    fi

    if [ "$NEW_CONF" = "$CURRENT" ]; then
      echo "$SSHD_LOG_PREFIX $SSHD_DROP unchanged — skipping"
    else
      echo "$SSHD_LOG_PREFIX deploying $SSHD_DROP"
      $SUDO mkdir -p /etc/ssh/sshd_config.d
      echo "$NEW_CONF" | $SUDO tee "$SSHD_DROP" > /dev/null
      $SUDO chmod 644 "$SSHD_DROP"
      if $SUDO systemctl is-active sshd >/dev/null 2>&1 || $SUDO systemctl is-active ssh >/dev/null 2>&1; then
        $SUDO systemctl reload sshd 2>/dev/null || $SUDO systemctl reload ssh 2>/dev/null || true
        echo "$SSHD_LOG_PREFIX sshd reloaded"
      fi
    fi
    ) || echo "[sshd-hardening] FAILED — see errors above, activation continues"
  '';
}
