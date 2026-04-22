# container-control-no-build-guardrails.nix — WARNING wrapper for docker
#
# Prints loud warnings when docker build/--build is used on small VMs.
# Does NOT block execution — just warns so operators notice.
# All images should be pre-built via GHCR or on oci-apps (ARM).
{ config, pkgs, lib, ... }:

{
  # Docker wrapper: warns on build commands, passes everything through
  home.file.".local/bin/docker" = {
    executable = true;
    text = ''
      #!/bin/sh
      case "$1" in
        build|buildx)
          echo "" >&2
          echo "╔══════════════════════════════════════════════════════════════╗" >&2
          echo "║  ⚠  WARNING: docker $1 on a small VM (<2GB RAM)           ║" >&2
          echo "║  This WILL likely OOM and freeze the VM.                   ║" >&2
          echo "║  Use GHCR pre-built images or build on oci-apps (24GB).   ║" >&2
          echo "╚══════════════════════════════════════════════════════════════╝" >&2
          ;;
        compose)
          for arg in "$@"; do
            case "$arg" in
              --build)
                echo "" >&2
                echo "╔══════════════════════════════════════════════════════════════╗" >&2
                echo "║  ⚠  WARNING: --build on a small VM — may OOM!             ║" >&2
                echo "║  Use: docker compose up -d --no-build                      ║" >&2
                echo "╚══════════════════════════════════════════════════════════════╝" >&2
                ;;
            esac
          done
          ;;
      esac
      # Strip .local/bin from PATH to find the real docker, then exec it
      PATH="$(printf "%s" "$PATH" | tr ':' '\n' | grep -v '\.local/bin' | tr '\n' ':')"
      exec docker "$@"
    '';
  };
}
