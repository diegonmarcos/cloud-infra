# Guardrails: PATH wrapper scripts in ~/.local/bin/
# Two-tier command protection (WARNING-ONLY — nothing is blocked or prompted):
#   WHITELIST → read-only / safe subcommands — pass through silently (no banner)
#   WARNING   → print reminder banner, log, then run the command
#
# Flow: whitelist? → pass silently | else → print warning + log + pass
#
# BUILDSH_GUARDRAIL=1 bypasses all banners (re-entry guard).
# All wrappers are POSIX sh — no bash required.
{ config, lib, ... }:

let
  managed = import ./infra-managed-header.nix { inherit lib; repo = "cloud/b_infra"; };

  # ── Tier 0: WHITELIST — read-only subcommands, pass immediately ────
  # These never modify the system. Needed for Claude Code internals
  # (npm root -g, npm config get prefix, etc.) and general safe queries.
  whitelist = [
    { cmd = "npm"; subcommands = [
      "root" "config" "prefix" "ls" "list" "ll" "la"
      "view" "info" "show" "search" "help" "explain"
      "doctor" "audit" "outdated" "fund" "pack" "ping"
      "whoami" "token" "profile" "access" "bugs" "repo"
      "completion" "explore" "-v" "--version" "-h" "--help"
    ]; }
    { cmd = "npx"; subcommands = [
      "-h" "--help" "--version" "-v"
    ]; }
    { cmd = "docker"; subcommands = [
      "ps" "images" "logs" "inspect" "top" "stats" "diff"
      "port" "version" "info" "events" "history" "search"
      "network ls" "network inspect" "volume ls" "volume inspect"
      "-v" "--version" "-h" "--help"
    ]; }
    { cmd = "nix"; subcommands = [
      "eval" "show-derivation" "path-info" "log" "why-depends"
      "build" "store" "hash" "flake show" "flake check" "flake info" "flake metadata"
      "registry list" "doctor" "profile list"
      "--version" "--help" "-h"
    ]; }
    { cmd = "pip"; subcommands = [
      "list" "show" "freeze" "check" "config"
      "--version" "-V" "--help" "-h"
    ]; }
    { cmd = "pip3"; subcommands = [
      "list" "show" "freeze" "check" "config"
      "--version" "-V" "--help" "-h"
    ]; }
  ];

  whitelistFor = cmd: let
    rules = builtins.filter (r: r.cmd == cmd) whitelist;
    subs = if rules == [] then [] else (builtins.head rules).subcommands;
  in subs;

  mkWhitelistCheck = cmd: let
    subs = whitelistFor cmd;
    # Split into single-word and two-word subcommands
    singleWord = builtins.filter (s: !lib.hasInfix " " s) subs;
    twoWord = builtins.filter (s: lib.hasInfix " " s) subs;
    # Group two-word subcommands by first word to avoid duplicate case patterns
    twoWordFirsts = lib.unique (map (s: builtins.elemAt (lib.splitString " " s) 0) twoWord);
    mkTwoGroup = first: let
      seconds = map (s: builtins.elemAt (lib.splitString " " s) 1)
        (builtins.filter (s: builtins.elemAt (lib.splitString " " s) 0 == first) twoWord);
      conditions = map (sec: ''[ "$_sub2" = "${sec}" ]'') seconds;
    in ''
      ${first}) if ${builtins.concatStringsSep " || " conditions}; then _log_guardrail "whitelist"; exec ${cmd} "$@" || _die "exec '${cmd}' failed (whitelist)"; fi ;;'';
    mkSingle = sub: ''
      ${sub}) _log_guardrail "whitelist"; exec ${cmd} "$@" || _die "exec '${cmd}' failed (whitelist)" ;;'';
    singleChecks = map mkSingle singleWord;
    twoChecks = map mkTwoGroup twoWordFirsts;
  in if subs == [] then "" else ''
    # Tier 0: WHITELIST — scan past flags to find the first two non-flag args
    _sub=""
    _sub2=""
    for _arg in "$@"; do
      case "$_arg" in
        -*) continue ;;
        *) if [ -z "$_sub" ]; then _sub="$_arg"; else _sub2="$_arg"; break; fi ;;
      esac
    done
    case "$_sub" in
    ${builtins.concatStringsSep "\n    " (twoChecks ++ singleChecks)}
    esac
  '';

  # ── Tier 1: DANGEROUS — flag patterns that could destroy data ──────
  # WARNING ONLY — prints a danger banner, logs it, then runs the command.
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

  # ── Tier 2: WARN — show declarative reminder, then run ─────────────
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

  # ── Rule matching helpers ──────────────────────────────────────────
  blockedRulesFor = cmd: builtins.filter (r: r.cmd == cmd) blocked;

  mkBlockChecks = cmd: let
    rules = blockedRulesFor cmd;
    mkCheck = rule: ''
      if printf " %s " "$ARGS" | grep -qiF -- "${rule.match}"; then
        printf "\n"
        printf "\033[1;31m  ╔══════════════════════════════════════════════════════════════╗\033[0m\n"
        printf "\033[1;31m  ║  ⚠ DANGER — DESTRUCTIVE OPERATION                           ║\033[0m\n"
        printf "\033[1;31m  ╠══════════════════════════════════════════════════════════════╣\033[0m\n"
        printf "\033[1;31m  ║  The command itself is fine. The flags are dangerous:        ║\033[0m\n"
        printf "\033[1;31m  ║                                                              ║\033[0m\n"
        printf "\033[1;33m  ║  ${rule.reason}\033[0m\n"
        printf "\033[1;31m  ║                                                              ║\033[0m\n"
        printf "\033[0;37m  ║  Ran: ${cmd} %s\033[0m\n" "$ARGS"
        printf "\033[1;31m  ║                                                              ║\033[0m\n"
        printf "\033[0;33m  ║  Use build.sh for safe deploy/compose operations.            ║\033[0m\n"
        printf "\033[1;31m  ╚══════════════════════════════════════════════════════════════╝\033[0m\n"
        _log_guardrail "danger"
        printf "\n"
      fi
    '';
  in builtins.concatStringsSep "\n" (map mkCheck rules);

  # ── Wrapper generator ──────────────────────────────────────────────
  mkWrapper = cmd: let
    blockChecks = mkBlockChecks cmd;
    whitelistCheck = mkWhitelistCheck cmd;
  in {
    name = ".local/bin/${cmd}";
    value = {
      executable = true;
      text = managed.inject { source = "_shared/modules/guardrails.nix"; text = (''
        #!/bin/sh
        # Error handling — NEVER fail silently
        _die() { printf "\033[1;31m  [guardrail/${cmd}] ERROR: %s\033[0m\n" "$1" >&2; exit 1; }

        # ── Logging: daily tier-specific logs with caller info ──
        _log_guardrail() {
          _tier="$1"
          _log_dir="$HOME/.local/log/guardrails"
          mkdir -p "$_log_dir" 2>/dev/null || return 0
          _date=$(date +%Y-%m-%d)
          _ts=$(date +%Y-%m-%dT%H:%M:%S%z)
          _logfile="$_log_dir/guardrails-$_date-$_tier.log"
          _ppid_cmd=$(ps -o comm= $PPID 2>/dev/null || echo "unknown")
          _ppid_full=$(cat /proc/$PPID/cmdline 2>/dev/null | tr '\0' ' ' | head -c 200 || echo "N/A")
          _tty_info="none"
          if [ -t 0 ] || [ -t 1 ]; then _tty_info=$(tty 2>/dev/null || echo "tty"); fi
          _ssh_info="local"
          if [ -n "''${SSH_CLIENT:-}" ]; then _ssh_info="ssh:$(echo "''${SSH_CLIENT}" | cut -d' ' -f1)"; fi
          _user=$(id -un 2>/dev/null || echo "unknown")
          printf '%s | %s %s | caller=%s(pid=%s) | cmdline=%s | tty=%s | %s | user=%s\n' \
            "$_ts" "${cmd}" "$ARGS" "$_ppid_cmd" "$PPID" "$_ppid_full" "$_tty_info" "$_ssh_info" "$_user" \
            >> "$_logfile" 2>/dev/null || true
        }

        # Strip ~/.local/bin from PATH so exec hits the real binary (must happen BEFORE any exec)
        PATH="$(printf "%s" "$PATH" | tr ':' '\n' | grep -v '\.local/bin' | tr '\n' ':')"

        # Bypass: BUILDSH_GUARDRAIL=1 skips all prompts (re-entry guard + auto-confirm)
        if [ "''${BUILDSH_GUARDRAIL:-}" = "1" ]; then
          exec ${cmd} "$@" || _die "exec '${cmd}' failed (not found on PATH?)"
        fi
        export BUILDSH_GUARDRAIL=1
        # Verify the real binary exists after PATH strip
        if ! command -v ${cmd} >/dev/null 2>&1; then
          _die "'${cmd}' not found on PATH after stripping ~/.local/bin. Is it installed?"
        fi
        ARGS="$*"
        ${whitelistCheck}
        ${blockChecks}
      '' + ''
        printf "\n"
        printf "\033[0;33m  ╔══════════════════════════════════════════════════════════════╗\033[0m\n"
        printf "\033[0;33m  ║  ⚠ REMINDER — DECLARATIVE ENVIRONMENT                       ║\033[0m\n"
        printf "\033[0;33m  ╠══════════════════════════════════════════════════════════════╣\033[0m\n"
        printf "\033[0;33m  ║  build.sh is the preferred interface for builds and deps.    ║\033[0m\n"
        printf "\033[0;33m  ║  Direct use is fine for quick tasks — just be aware.         ║\033[0m\n"
        printf "\033[0;33m  ╚══════════════════════════════════════════════════════════════╝\033[0m\n"
        printf "\n"
        _log_guardrail "warning"
        exec ${cmd} "$@" || _die "exec '${cmd}' failed"
      ''); };
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
