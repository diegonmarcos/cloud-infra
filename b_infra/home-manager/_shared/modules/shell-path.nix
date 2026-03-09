# Ensure nix-profile binaries are in PATH for ALL bash sessions
# (interactive, non-interactive SSH, cron, scripts).
# bashrcExtra runs BEFORE the interactivity guard in .bashrc.
{ lib, ... }:
{
  programs.bash.bashrcExtra = lib.mkBefore ''
    export PATH="$HOME/.nix-profile/bin:$HOME/.local/bin:$PATH"
  '';
}
