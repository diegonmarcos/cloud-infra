# Creates the `infra` Docker network with a fixed subnet on activation.
# This replaces npm_default / dev_network — all containers join `infra`.
#
# Must run AFTER docker.service starts (entryAfter dockerService).
# Services depend on this network existing before `docker compose up`.
#
# Usage in VM config:
#   (import ./modules/docker-network.nix {
#     vmName  = "gcp-proxy";
#     subnet  = "172.20.0.0/24";
#     gateway = "172.20.0.1";
#   })

{ vmName, subnet, gateway }:

{ config, lib, pkgs, ... }:

{
  home.activation.dockerNetwork = lib.hm.dag.entryAfter ["dockerService"] ''
    (
    trap 'echo "[docker-network] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR

    # Wait for Docker to be available (up to 30s)
    _TRIES=0
    until docker info >/dev/null 2>&1 || [ $_TRIES -ge 30 ]; do
      _TRIES=$((_TRIES + 1))
      sleep 1
    done
    if ! docker info >/dev/null 2>&1; then
      echo "[docker-network] WARNING: Docker not ready after 30s — skipping"
      exit 0
    fi

    # Create infra network if not present
    if ! docker network inspect infra >/dev/null 2>&1; then
      docker network create \
        --driver bridge \
        --subnet ${subnet} \
        --gateway ${gateway} \
        --opt com.docker.network.bridge.name=br-infra \
        infra
      echo "[docker-network] Created infra network (${subnet}) for ${vmName}"
    else
      echo "[docker-network] infra network exists — skipping create"
    fi
    ) || echo "[docker-network] FAILED — see errors above, activation continues"
  '';
}
