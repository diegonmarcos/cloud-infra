# Ensure nix-profile binaries are in PATH for ALL contexts:
# - home.sessionPath → ~/.profile (login shells, SSH sessions)
# - home.sessionVariables → ~/.profile (env vars)
# - /etc/environment → PAM-level, covers non-login non-interactive SSH (GHA, cron, scripts)
{ lib, pkgs, config, ... }:
{
  home.sessionPath = [
    "$HOME/.nix-profile/bin"
    "$HOME/.local/bin"
    "/nix/var/nix/profiles/default/bin"
  ];

  home.sessionVariables = {
    SSL_CERT_FILE = "$HOME/.nix-profile/etc/ssl/certs/ca-bundle.crt";
    NIX_SSL_CERT_FILE = "$HOME/.nix-profile/etc/ssl/certs/ca-bundle.crt";
  };

  # /etc/environment is read by PAM before any shell — covers ALL session types
  # including non-login non-interactive SSH (where bash skips all dotfiles).
  home.activation.nixPathEtcEnvironment = lib.hm.dag.entryAfter ["writeBoundary"] ''
    (
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    if [ -z "$SUDO" ]; then
      echo "[shell-path] WARNING: sudo not found — skipping /etc/environment"
      exit 0
    fi

    NIX_PATHS="/home/${config.home.username}/.nix-profile/bin:/nix/var/nix/profiles/default/bin"

    # Ensure /etc/environment exists
    $SUDO touch /etc/environment

    if $SUDO grep -qF '.nix-profile/bin' /etc/environment 2>/dev/null; then
      echo "[shell-path] /etc/environment already has nix PATH"
    else
      # Prepend nix paths to existing PATH or add new PATH line
      if $SUDO grep -q '^PATH=' /etc/environment 2>/dev/null; then
        $SUDO sed -i "s|^PATH=|PATH=$NIX_PATHS:|" /etc/environment
      else
        echo "PATH=$NIX_PATHS:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" | $SUDO tee -a /etc/environment >/dev/null
      fi
      echo "[shell-path] Added nix paths to /etc/environment"
    fi
    ) || echo "[shell-path] FAILED — see errors above, activation continues"
  '';
}
