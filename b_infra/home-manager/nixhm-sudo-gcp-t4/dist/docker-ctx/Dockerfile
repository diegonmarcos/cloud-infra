FROM ghcr.io/diegonmarcos/user-dev-x86-deb-nix-hm:latest
USER root
LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
LABEL org.opencontainers.image.description="Home-Manager activation image for nixhm-sudo-gcp-t4"
COPY nix-store/ /nix/store/
COPY activate.sh /hm/activate.sh
COPY secrets.yaml /hm/secrets.yaml
COPY nix-closure.nar.gz /hm/nix-closure.nar.gz
COPY nix-register-validity.txt /hm/nix-register-validity.txt
RUN chmod +x /hm/activate.sh
ENV HM_ACTIVATION_PATH=/nix/store/razzkfbymm1zz939d0nykwfj46w4m66y-home-manager-generation
ENV HM_USER=diego
ENTRYPOINT ["/bin/bash", "/hm/activate.sh"]
