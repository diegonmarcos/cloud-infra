# Ensure nix-profile binaries are in PATH for ALL contexts:
# - home.sessionPath → ~/.profile (login shells, SSH sessions)
# - home.sessionVariables → ~/.profile (env vars)
# - bashrcExtra → .bashrc (interactive + non-interactive bash)
{ lib, pkgs, ... }:
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
}
