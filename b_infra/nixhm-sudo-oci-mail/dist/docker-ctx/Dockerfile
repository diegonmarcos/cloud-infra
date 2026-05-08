# vm-pilot transport Dockerfile — shared across all nixhm-sudo-{vm} images
#
# Each per-VM HM image is built by the cloud engine from this template,
# substituting:
#   nixhm-sudo-oci-mail        → e.g. "nixhm-sudo-oci-mail"
#   /nix/store/nhjib6lpl124hfqz3gm21r2hyy87ipfq-home-manager-generation  → /nix/store/<hash>-home-manager-generation
#   ubuntu             → the per-VM user (ubuntu, diego, etc.)
#
# Architecture note (why so minimal):
#   The VM ALREADY has nix-daemon installed natively. This container's only
#   job is to deliver the closure bytes to host's /nix/store; the activation
#   itself runs NATIVELY on the VM after the container exits. So this image
#   needs nothing beyond the bash + coreutils that activate.sh invokes
#   (cp, find, stat, awk, mkdir, rm, etc.) — all of which are already
#   present in `debian:bookworm-slim` straight out of the box.
#
#   No apt-install required. No nix runtime required. ~30 MB base layer.
#
#   FUTURE: if ever shipping to a fresh VM without nix-daemon, an apt-install
#   layer (curl + xz-utils + ca-certificates) and a bootstrap step in
#   activate.sh will be needed. All 4 active VMs already have nix-daemon.
#
# Source-of-truth: b_infra/_shared/vm-pilot/src/Dockerfile.transport
# Consumed by:    1_workflows/src/scripts/cloud-ship-nix-homemanager-step-build-docker.sh
FROM debian:bookworm-slim

USER root
LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
LABEL org.opencontainers.image.description="Home-Manager activation image for nixhm-sudo-oci-mail"

COPY nix-store/ /nix/store/
COPY activate.sh /hm/activate.sh
COPY nix-db-dump.txt /hm/nix-db-dump.txt
RUN chmod +x /hm/activate.sh

ENV HM_ACTIVATION_PATH=/nix/store/nhjib6lpl124hfqz3gm21r2hyy87ipfq-home-manager-generation
ENV HM_USER=ubuntu
ENTRYPOINT ["/bin/bash", "/hm/activate.sh"]
