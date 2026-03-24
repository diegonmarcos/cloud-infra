# Shared CLI tools — imported by ALL VMs.
# Containers mount ~/.nix-profile/bin to share these binaries.
# Cloud-specific SDKs (gcloud, oci) go in the VM-specific .nix file.
{ pkgs, ... }:

{
  home.packages = with pkgs; [
    # ── Code analysis ──
    (callPackage ../pkgs/octocode.nix {})

    # ── Secrets ──
    sops
    age

    # ── JSON/YAML ──
    jq
    yq-go

    # ── File transfer ──
    rsync
    rclone

    # ── Network ──
    curl
    wget
    netcat
    iputils        # ping
    openssl
    bind           # dig, nslookup
    socat

    # ── System ──
    htop
    btop
    ncdu
    tree
    lsof
    iftop
    bc
    inotify-tools

    # ── Git ──
    git
    gh
    cacert          # CA certificates — needed by nix git/curl inside containers

    # ── Text ──
    ripgrep
    fd
    bat

    # ── Compression ──
    gzip
    unzip
    zip

    # ── Container runtime ──
    docker
    docker-compose
    docker-buildx
    podman

    # ── Database clients (used by db-agent, photos-webhook) ──
    sqlite
    postgresql_16
    mariadb

    # ── Backup ──
    bup

    # ── WireGuard ──
    wireguard-tools

    # ── Security scanning (used by sauron-lite) ──
    yara
  ];

  # Static busybox for Docker healthcheck probes in distroless containers.
  # Bind-mount ~/bin/busybox-static into containers that lack wget/nc.
  home.file."bin/busybox-static" = {
    source = "${pkgs.pkgsStatic.busybox}/bin/busybox";
  };
}
