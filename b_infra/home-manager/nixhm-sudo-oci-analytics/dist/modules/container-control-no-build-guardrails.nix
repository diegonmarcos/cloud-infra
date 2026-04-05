# container-control-no-build-guardrails.nix — Block docker build on VMs
#
# Ensures `docker compose up` NEVER triggers builds.
# All images must be pre-built via GHCR or on oci-apps (ARM).
# Wraps docker to intercept build commands.
{ config, pkgs, lib, ... }:

let
  cloudData = builtins.fromJSON (builtins.readFile ./cloud-data-home-manager.json);
in {
  # Deploy docker wrapper that blocks build subcommands
  home.file.".local/share/container-control/docker-no-build-wrapper.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      # Block docker build/buildx on this VM — images must be pre-built via GHCR
      # Managed by container-control-no-build-guardrails.nix
      REAL_DOCKER="$(command -v docker.real 2>/dev/null || echo "")"
      [ -z "$REAL_DOCKER" ] && REAL_DOCKER="$(readlink -f /usr/bin/docker 2>/dev/null || echo "")"

      for arg in "$@"; do
        case "$arg" in
          build|buildx)
            echo "[BLOCKED] docker $arg is disabled on this VM." >&2
            echo "  Images must be pre-built via GHCR or on oci-apps." >&2
            echo "  Use: build.sh docker  (builds + pushes to GHCR)" >&2
            exit 1
            ;;
          --build)
            echo "[BLOCKED] docker compose --build is disabled on this VM." >&2
            echo "  Use: docker compose up -d --no-build" >&2
            exit 1
            ;;
        esac
      done

      exec "$REAL_DOCKER" "$@"
    '';
  };
}
