FROM ghcr.io/diegonmarcos/user-dev-x86-deb-nix-hm:latest
USER root
LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
LABEL org.opencontainers.image.description="Home-Manager activation image for nixhm-sudo-gcp-proxy"
COPY nix-store/ /nix/store/
COPY activate.sh /hm/activate.sh
COPY nix-db-dump.txt /hm/nix-db-dump.txt
RUN chmod +x /hm/activate.sh
ENV HM_ACTIVATION_PATH=/nix/store/m5ji4w5l7567y3l81as4szpmzqmxdc0q-home-manager-generation
ENV HM_USER=diego
ENTRYPOINT ["/bin/bash", "/hm/activate.sh"]
