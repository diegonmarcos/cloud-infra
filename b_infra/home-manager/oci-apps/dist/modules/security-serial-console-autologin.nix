# Serial console autologin — passwordless ttyS0 for OCI/GCP serial rescue
# Drops a systemd override for serial-getty@ttyS0 with --autologin
{ config, pkgs, lib, ... }:

{
  home.activation.serialConsoleAutologin = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    (
    trap 'echo "[serial-autologin] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
    LOG="[serial-autologin]"

    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    if [ -z "$SUDO" ]; then
      echo "$LOG WARN: sudo not found — skipping"
      exit 0
    fi

    # Detect current user for autologin
    AUTOLOGIN_USER="$(whoami)"

    OVERRIDE_DIR="/etc/systemd/system/serial-getty@ttyS0.service.d"
    OVERRIDE_FILE="$OVERRIDE_DIR/autologin.conf"

    DESIRED="[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $AUTOLOGIN_USER --noclear --keep-baud 115200,57600,38400,9600 %I \$TERM"

    # Check if already correct
    if $SUDO test -f "$OVERRIDE_FILE"; then
      CURRENT="$($SUDO cat "$OVERRIDE_FILE" 2>/dev/null)"
      if [ "$CURRENT" = "$DESIRED" ]; then
        echo "$LOG already configured for $AUTOLOGIN_USER"
        exit 0
      fi
    fi

    echo "$LOG configuring autologin on ttyS0 for user $AUTOLOGIN_USER"
    $SUDO mkdir -p "$OVERRIDE_DIR"
    echo "$DESIRED" | $SUDO tee "$OVERRIDE_FILE" >/dev/null
    $SUDO systemctl daemon-reload
    $SUDO systemctl restart serial-getty@ttyS0.service 2>/dev/null || true
    echo "$LOG done"
    )
  '';
}
