# Guardrails: PATH wrapper scripts in ~/.local/bin/
# Three-tier command protection:
#   BLOCKED   → dangerous flag combos that wipe databases/volumes — hard stop
#   CONFIRM   → declarative reminder + ask y/N (auto-confirmed by build.sh)
#   WARNING   → reminder banner, then run
#   (no match on flags → falls through to CONFIRM or WARNING tier)
#
# build.sh sets BUILDSH_GUARDRAIL=1 to auto-confirm tier 2.
# BLOCKED is never bypassed, not even by build.sh.
# All wrappers are POSIX sh — no bash required.
{ config, lib, ... }:

let
  # ── Tier 1: BLOCKED — flag patterns that destroy data ──────────────
  # The COMMAND is fine. The ARGS are the problem.
  blocked = [
    { cmd = "docker";         match = "compose down -v";           reason = "'-v' wipes Docker volumes — databases, state, everything persistent"; }
    { cmd = "docker";         match = "compose down --volumes";    reason = "'--volumes' wipes Docker volumes — databases, state, everything persistent"; }
    { cmd = "docker";         match = "volume rm";                 reason = "'volume rm' permanently deletes named volumes — databases live there"; }
    { cmd = "docker";         match = "volume prune";              reason = "'volume prune' deletes ALL unused volumes — may contain databases"; }
    { cmd = "docker";         match = "system prune -a --volumes"; reason = "'--volumes' with system prune removes everything including databases"; }
    { cmd = "docker-compose"; match = "down -v";                   reason = "'-v' wipes Docker volumes — databases, state, everything persistent"; }
    { cmd = "docker-compose"; match = "down --volumes";            reason = "'--volumes' wipes Docker volumes — databases, state, everything persistent"; }
    { cmd = "rsync";          match = "--delete";                  reason = "'--delete' removes remote files not in source — use build.sh deploy instead"; }
  ];

  # ── Tier 2: CONFIRM — show declarative reminder + ask y/N ──────────
  # All commands that were already wrapped (the original 24)
  confirmCmds = [
    "npm" "npx" "apt" "apt-get" "pkg" "pip" "pip3" "nix-env"
    "yarn" "pnpm" "docker" "docker-compose" "nix" "nixos-rebuild"
    "home-manager" "snap" "flatpak" "pacman" "yay" "paru"
    "dnf" "yum" "brew" "pipx" "conda" "poetry" "uv"
  ];

  # ── Tier 3: WARNING — reminder banner, then run ────────────────────
  # Safe build/dev tools — you need them to work, just a nudge
  warningCmds = [ "bun" "cargo" "go" ];

  # Commands from blocked rules need wrappers too (so flags get intercepted)
  blockedCmds = lib.unique (map (r: r.cmd) blocked);

  # All commands that need wrappers
  allCommands = lib.unique (confirmCmds ++ warningCmds ++ blockedCmds);

  # ── Read-only subcommands that bypass confirmation ────────────────
  # These can't modify the system — safe to run without prompting.
  # Prevents hanging when called from non-interactive shells (e.g. Claude Code).
  readOnly = {
    npm  = [ "config" "root" "prefix" "ls" "list" "view" "info" "explain" "help" "version" "query" "why" ];
    npx  = [];
    nix  = [ "eval" "flake" "show" "search" "path-info" "derivation" "log" "why-depends" "store" ];
  };

  # Generate whitelist check: scan all args (not just $1) for read-only subcommands
  mkWhitelistCheck = cmd: let
    subs = readOnly.${cmd} or [];
    cases = lib.concatStringsSep "|" subs;
  in if subs == [] then "" else ''
        # Whitelist read-only subcommands — skip confirmation
        for _arg in "$@"; do
          case "$_arg" in
            -*) continue ;;
            ${cases}) exec ${cmd} "$@" ;;
            *) break ;;
          esac
        done
  '';

  # ── Rule matching helpers ──────────────────────────────────────────
  blockedRulesFor = cmd: builtins.filter (r: r.cmd == cmd) blocked;

  mkBlockChecks = cmd: let
    rules = blockedRulesFor cmd;
    mkCheck = rule: ''
      if printf " %s " "$ARGS" | grep -qiF -- "${rule.match}"; then
        printf "\n"
        printf "\033[1;31m  ╔══════════════════════════════════════════════════════════════╗\033[0m\n"
        printf "\033[1;31m  ║  ✖ BLOCKED — DESTRUCTIVE OPERATION                          ║\033[0m\n"
        printf "\033[1;31m  ╠══════════════════════════════════════════════════════════════╣\033[0m\n"
        printf "\033[1;31m  ║  The command itself is fine. The flags are the problem:      ║\033[0m\n"
        printf "\033[1;31m  ║                                                              ║\033[0m\n"
        printf "\033[1;33m  ║  ${rule.reason}\033[0m\n"
        printf "\033[1;31m  ║                                                              ║\033[0m\n"
        printf "\033[0;37m  ║  Ran: ${cmd} %s\033[0m\n" "$ARGS"
        printf "\033[1;31m  ║                                                              ║\033[0m\n"
        printf "\033[0;33m  ║  Use build.sh for safe deploy/compose operations.            ║\033[0m\n"
        printf "\033[1;31m  ╚══════════════════════════════════════════════════════════════╝\033[0m\n"
        printf "\n"
        exit 1
      fi
    '';
  in builtins.concatStringsSep "\n" (map mkCheck rules);

  # ── Wrapper generator ──────────────────────────────────────────────
  mkWrapper = cmd: let
    isWarning = builtins.elem cmd warningCmds;
    blockChecks = mkBlockChecks cmd;
    whitelistCheck = mkWhitelistCheck cmd;
  in {
    name = ".local/bin/${cmd}";
    value = {
      executable = true;
      text = ''
        #!/bin/sh
        # Re-entry guard: skip if already inside a guardrail wrapper
        if [ "''${_GUARDRAIL:-}" = "1" ]; then exec ${cmd} "$@"; fi
        export _GUARDRAIL=1
        # Strip ~/.local/bin from PATH so exec hits the real binary
        PATH="$(printf "%s" "$PATH" | tr ':' '\n' | grep -v '\.local/bin' | tr '\n' ':')"
        ARGS="$*"
        ${whitelistCheck}
        ${blockChecks}
      '' + (if isWarning then ''
        printf "\n"
        printf "\033[0;33m  ╔══════════════════════════════════════════════════════════════╗\033[0m\n"
        printf "\033[0;33m  ║  ⚠ REMINDER                                                 ║\033[0m\n"
        printf "\033[0;33m  ╠══════════════════════════════════════════════════════════════╣\033[0m\n"
        printf "\033[0;33m  ║  build.sh is the preferred interface for builds and deps.    ║\033[0m\n"
        printf "\033[0;33m  ║  Direct use is fine for quick tasks — just be aware.         ║\033[0m\n"
        printf "\033[0;33m  ╚══════════════════════════════════════════════════════════════╝\033[0m\n"
        printf "\n"
        exec ${cmd} "$@"
      '' else ''
        if [ "''${BUILDSH_GUARDRAIL:-}" = "1" ]; then
          exec ${cmd} "$@"
        fi
        printf "\n"
        printf "\033[1;31m  ╔══════════════════════════════════════════════════════════════╗\033[0m\n"
        printf "\033[1;31m  ║  ⚠ CONFIRM — DECLARATIVE ENVIRONMENT                        ║\033[0m\n"
        printf "\033[1;31m  ╠══════════════════════════════════════════════════════════════╣\033[0m\n"
        printf "\033[1;31m  ║  1) DECLARATIVE ONLY                                         ║\033[0m\n"
        printf "\033[1;31m  ║     THIS IS A FULL DECLARATIVE ENVIRONMENT, NIX-FLAKES WAY  ║\033[0m\n"
        printf "\033[1;31m  ╠══════════════════════════════════════════════════════════════╣\033[0m\n"
        printf "\033[1;33m  ║  2) BUILD.SH ALWAYS                                          ║\033[0m\n"
        printf "\033[1;33m  ║     JS deps  → build.sh deps | Build → build.sh build        ║\033[0m\n"
        printf "\033[1;33m  ╠══════════════════════════════════════════════════════════════╣\033[0m\n"
        printf "\033[1;35m  ║  3) NO HARDCODE EASY FIX                                     ║\033[0m\n"
        printf "\033[1;35m  ║     Always report a bug in the build.sh engine               ║\033[0m\n"
        printf "\033[1;35m  ╚══════════════════════════════════════════════════════════════╝\033[0m\n"
        printf "\n"
        printf "\033[0;36m  Source: ~/git/cloud/b_infra/home-manager/_shared/modules/guardrails.nix\033[0m\n"
        printf "\n"
        printf "\033[1;37m  Proceed? [y/N] \033[0m"
        if ! read -t 5 -r REPLY < /dev/tty 2>/dev/null; then
          printf "\n\033[0;31m  [guardrail] BLOCKED (no TTY or timeout): ${cmd} %s\033[0m\n" "$ARGS" >&2
          printf "\033[0;33m  Source: ~/git/cloud/b_infra/home-manager/_shared/modules/guardrails.nix\033[0m\n" >&2
          exit 1
        fi
        if [ "$REPLY" != "y" ] && [ "$REPLY" != "Y" ]; then
          printf "\033[0;31m  Aborted.\033[0m\n"
          exit 1
        fi
        exec ${cmd} "$@"
      '');
    };
  };

in
{
  # Prepend ~/.local/bin so wrappers intercept before ~/.nix-profile/bin
  # initExtra covers interactive shells, profileExtra covers login shells
  programs.bash.initExtra = lib.mkBefore ''
    export PATH="$HOME/.local/bin:$PATH"
  '';
  programs.bash.profileExtra = lib.mkAfter ''
    export PATH="$HOME/.local/bin:$PATH"
  '';
  home.file = builtins.listToAttrs (map mkWrapper allCommands);
}
