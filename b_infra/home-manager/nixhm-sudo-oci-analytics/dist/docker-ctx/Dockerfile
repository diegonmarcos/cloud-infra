FROM ghcr.io/diegonmarcos/user-dev-x86-deb-nix-hm:latest
USER root
LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
LABEL org.opencontainers.image.description="Home-Manager activation image for nixhm-sudo-oci-analytics"
COPY nix-store/ /nix/store/
COPY activate.sh /hm/activate.sh
COPY nix-db-dump.txt /hm/nix-db-dump.txt
RUN chmod +x /hm/activate.sh
ENV HM_ACTIVATION_PATH=/nix/store/jzqr4wcqp7y0jqv4ghsg9x4jzc8g4z8i-home-manager-generation
ENV HM_USER=ubuntu
ENTRYPOINT ["/bin/bash", "/hm/activate.sh"]
