# No-Build Guard — HARD block on build tools for resource-constrained VMs
#
# Two layers:
#   1. REMOVAL: systemd oneshot on every boot removes nix-build, nix-instantiate,
#      docker buildx from the system. If they get reinstalled, next boot removes them.
#   2. WRAPPER: ~/.local/bin/ wrappers explain WHY the tool is blocked.
#      Even if someone bypasses the wrapper, the real binary is gone.
#
# Only oci-apps* (ARM, 24GB) should be excluded from this module.
# All x86 VMs (gcp-proxy, oci-mail, oci-analytics) MUST import this.
{ config, lib, pkgs, ... }:

let
  blockedBins = [
    "nix-build"
    "nix-instantiate"
  ];

  blockedDockerCmds = [ "build" "buildx" ];

  explanation = bin: ''
    #!/bin/sh
    echo "" >&2
    echo "╔══════════════════════════════════════════════════════════════╗" >&2
    echo "║  BLOCKED: ${bin} is removed on this VM                      ║" >&2
    echo "╠══════════════════════════════════════════════════════════════╣" >&2
    echo "║  This VM has <2GB RAM — builds will OOM and freeze it.     ║" >&2
    echo "║                                                            ║" >&2
    echo "║  WHERE TO BUILD:                                           ║" >&2
    echo "║    • nix build  → GHA runner (x86_64) or local machine     ║" >&2
    echo "║    • docker build → GHA runner or oci-apps (ARM, 24GB)     ║" >&2
    echo "║                                                            ║" >&2
    echo "║  HOW TO DEPLOY:                                            ║" >&2
    echo "║    • build.sh ship (builds on runner, deploys result)      ║" >&2
    echo "║    • nix copy --to ssh://vm (pre-built closure)            ║" >&2
    echo "║    • docker pull (GHCR pre-built image)                    ║" >&2
    echo "╚══════════════════════════════════════════════════════════════╝" >&2
    echo "" >&2
    exit 1
  '';
in {

  # ── Systemd service: remove build binaries on every boot ──────────
  home.file.".local/share/no-build-guard/no-build-guard.service".text = ''
    [Unit]
    Description=No-Build Guard — remove build tools from resource-constrained VM
    After=network.target
    Before=docker.service

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/bin/sh -c '\
      LOG=/var/log/no-build-guard.log; \
      echo "$(date -Is) [no-build-guard] Scanning for build tools..." >> "$LOG"; \
      REMOVED=0; \
      for bin in nix-build nix-instantiate; do \
        for path in \
          /nix/var/nix/profiles/default/bin/$bin \
          /root/.nix-profile/bin/$bin \
          /home/*/nix-profile/bin/$bin \
          /usr/local/bin/$bin \
          /usr/bin/$bin; do \
          if [ -f "$path" ] || [ -L "$path" ]; then \
            rm -f "$path" 2>/dev/null && \
              echo "$(date -Is) [no-build-guard] REMOVED: $path" >> "$LOG" && \
              REMOVED=$((REMOVED + 1)) || true; \
          fi; \
        done; \
      done; \
      # Remove docker buildx plugin \
      for d in /usr/lib/docker/cli-plugins /usr/libexec/docker/cli-plugins /root/.docker/cli-plugins /home/*/.docker/cli-plugins; do \
        if [ -f "$d/docker-buildx" ]; then \
          rm -f "$d/docker-buildx" 2>/dev/null && \
            echo "$(date -Is) [no-build-guard] REMOVED: $d/docker-buildx" >> "$LOG" && \
            REMOVED=$((REMOVED + 1)) || true; \
        fi; \
      done; \
      echo "$(date -Is) [no-build-guard] Done: $REMOVED binaries removed" >> "$LOG"; \
    '

    [Install]
    WantedBy=multi-user.target
  '';

  # ── Wrapper scripts: explain the situation ────────────────────────
  home.file.".local/bin/nix-build" = {
    executable = true;
    text = explanation "nix-build";
  };

  home.file.".local/bin/nix-instantiate" = {
    executable = true;
    text = explanation "nix-instantiate";
  };

  # Docker wrapper: blocks build/buildx subcommands, passes everything else
  home.file.".local/bin/docker" = {
    executable = true;
    text = ''
      #!/bin/sh
      case "$1" in
        build|buildx)
          echo "" >&2
          echo "╔══════════════════════════════════════════════════════════════╗" >&2
          echo "║  BLOCKED: docker $1 is disabled on this VM                 ║" >&2
          echo "╠══════════════════════════════════════════════════════════════╣" >&2
          echo "║  This VM has <2GB RAM — docker builds will OOM it.         ║" >&2
          echo "║  Use GHCR pre-built images or build on oci-apps (ARM).     ║" >&2
          echo "╚══════════════════════════════════════════════════════════════╝" >&2
          exit 1
          ;;
        compose)
          for arg in "$@"; do
            case "$arg" in --build)
              echo "[no-build-guard] WARNING: docker compose --build on resource-constrained VM — may OOM" >&2
              ;; esac
          done
          ;;
      esac
      PATH="$(printf "%s" "$PATH" | tr ':' '\n' | grep -v '\.local/bin' | tr '\n' ':')"
      exec docker "$@"
    '';
  };

  # ── Activation: install + enable the systemd service ──────────────
  home.activation.noBuildGuard = lib.hm.dag.entryAfter ["writeBoundary"] ''
    (
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && echo "[no-build-guard] no sudo — skipping" && exit 0

    SRC="$HOME/.local/share/no-build-guard"
    $SUDO cp -f "$SRC/no-build-guard.service" /etc/systemd/system/no-build-guard.service
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable no-build-guard.service 2>/dev/null || true
    $SUDO systemctl start no-build-guard.service 2>/dev/null || true

    echo "[no-build-guard] Active: nix-build + nix-instantiate + docker buildx REMOVED on every boot"
    ) || echo "[no-build-guard] FAILED — see errors above"
  '';
}
