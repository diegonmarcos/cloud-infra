# SSH daemon hardening — drops a config snippet into /etc/ssh/sshd_config.d/
# Fixes 50s+ SSH delays caused by reverse DNS lookups (UseDNS)
{ config, pkgs, lib, ... }:

{
  home.activation.sshdHardening = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    SSHD_DROP="/etc/ssh/sshd_config.d/10-hardening.conf"
    SSHD_OLD="/etc/ssh/sshd_config.d/90-hardening.conf"
    SSHD_LOG_PREFIX="[sshd-hardening]"

    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    if [ -z "$SUDO" ]; then
      echo "$SSHD_LOG_PREFIX WARN: sudo not found — skipping sshd hardening"
      return 0
    fi

    # Clean up old filename
    if $SUDO test -f "$SSHD_OLD"; then
      echo "$SSHD_LOG_PREFIX removing old $SSHD_OLD"
      $SUDO rm -f "$SSHD_OLD"
    fi

    NEW_CONF="# Managed by home-manager (sshd-hardening.nix) — do not edit
UseDNS no
GSSAPIAuthentication no
"

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
  '';
}
