# Shared CLI tools — imported by ALL VMs.
# Containers mount ~/.nix-profile/bin to share these binaries.
# Cloud-specific SDKs (gcloud, oci) go in the VM-specific .nix file.
{ lib, pkgs, ... }:

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
    tmux
    ttyd
    ncdu
    tree
    lsof
    iftop
    iotop
    sysstat      # iostat, mpstat, pidstat, sar
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

    # ── Node.js runtime (shared with containers via nix-profile bind mount) ──
    nodejs_22

    # ── Container runtime ──
    docker
    docker-compose
    docker-buildx
    youki            # Rust OCI runtime — replaces runc (Go), lighter per-container overhead
    podman

    # ── Database clients (used by db-agent, photos-webhook) ──
    sqlite
    postgresql_16
    mariadb

    # ── Backup ──
    rustic-rs

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

  # HM always wins — remove imperative nix profile packages that conflict
  home.activation.removeImperativePackages = lib.hm.dag.entryBefore ["installPackages"] ''
    if command -v nix >/dev/null 2>&1 && nix profile list >/dev/null 2>&1; then
      for pkg in $(nix profile list 2>/dev/null | grep "^Name:" | sed 's/.*Name:[[:space:]]*//' | sed 's/\x1b\[[0-9;]*m//g'); do
        echo "[hm] Removing imperative nix profile package: $pkg"
        nix profile remove "$pkg" 2>/dev/null || true
      done
    fi
  '';

  # Auto-update git submodules in all repos on activation.
  # Ensures cloud-data submodule is always fresh.
  home.activation.gitSubmoduleUpdate = lib.hm.dag.entryAfter ["linkGeneration"] ''
    for repo in "$HOME/git/cloud" "$HOME/git/front" "$HOME/git/unix"; do
      [ -d "$repo/.git" ] || continue
      [ -f "$repo/.gitmodules" ] || continue
      printf "[git-submodules] Updating submodules in %s\n" "$repo"
      ${pkgs.git}/bin/git -C "$repo" submodule update --remote --init 2>/dev/null || true
    done
  '';
}
