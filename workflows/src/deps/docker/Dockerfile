# ╔══════════════════════════════════════════════════════════════════╗
# ║ cloud-builder — Self-contained CI/CD builder image              ║
# ║                                                                  ║
# ║ Contains: nix + devShell (sops, rsync, ssh, git, jq, yq, node)  ║
# ║ Does NOT contain: code, secrets, service outputs (built fresh)   ║
# ║                                                                  ║
# ║ Source: workflows/src/deps/docker/Dockerfile                     ║
# ║ Registry: ghcr.io/diegonmarcos/cloud-builder                    ║
# ╚══════════════════════════════════════════════════════════════════╝

FROM nixos/nix:latest AS builder

# Enable flakes
RUN mkdir -p /etc/nix && echo "experimental-features = nix-command flakes" > /etc/nix/nix.conf

# Copy deps flake (context is workflows/src/deps/)
WORKDIR /build
COPY flake.nix flake.lock ./

# Fetch config.json from GitHub (same as flake input does)
RUN nix flake update config-json --flake .

# Build the devShell — populates nix store with all deps
RUN nix build .#devShells.x86_64-linux.default.inputDerivation --no-link

# Also pre-populate nixpkgs evaluations for faster service builds
RUN nix eval --json .#devShells.x86_64-linux.default.name > /dev/null

# Install npm packages to /root/.node_modules (shared node deps)
RUN nix develop .# --command bash -c '\
    mkdir -p /root/.node_modules && \
    cd /root/.node_modules && \
    npm install --silent tsx yaml nunjucks 2>/dev/null && \
    echo "Node modules installed: $(ls node_modules | wc -l) packages"'

# ── Final image: nix store + node_modules ready ──
FROM nixos/nix:latest

RUN mkdir -p /etc/nix && echo "experimental-features = nix-command flakes" > /etc/nix/nix.conf

# Copy populated nix store from builder
COPY --from=builder /nix/store /nix/store
COPY --from=builder /nix/var /nix/var

# Copy node_modules
COPY --from=builder /root/.node_modules /root/.node_modules

# Copy deps flake for nix develop at runtime
COPY --from=builder /build /opt/deps-flake

# Labels
LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
LABEL org.opencontainers.image.description="cloud-builder — self-contained CI/CD image (nix, sops, rsync, ssh)"

# Default: drop into nix develop shell
WORKDIR /workspace
ENTRYPOINT ["nix", "develop", "/opt/deps-flake#", "--command"]
CMD ["bash"]
