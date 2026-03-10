# Ensure nix-profile binaries are in PATH for ALL bash sessions
# (interactive, non-interactive SSH, cron, scripts).
# bashrcExtra runs BEFORE the interactivity guard in .bashrc.
{ lib, pkgs, ... }:
{
  programs.bash.bashrcExtra = lib.mkBefore ''
    export PATH="$HOME/.nix-profile/bin:$HOME/.local/bin:$PATH"
    export SSL_CERT_FILE="$HOME/.nix-profile/etc/ssl/certs/ca-bundle.crt"
    export NIX_SSL_CERT_FILE="$SSL_CERT_FILE"
  '';
}
