# Declarative system package cleanup
# Removes OS-level packages that conflict with nix-profile binaries.
# Runs on every home-manager activation to prevent drift.
#
# Why: Ubuntu/Fedora ship docker, containerd, runc, snapd etc. that
# shadow or conflict with nix-managed versions. This module ensures
# only nix binaries are used.
{ config, lib, pkgs, ... }:

let
  # Packages to remove — these conflict with nix-profile binaries
  # or are unnecessary on declaratively managed VMs
  debPackages = [
    "docker.io"
    "docker-ce"
    "docker-ce-cli"
    "docker-ce-rootless-extras"
    "docker-buildx-plugin"
    "docker-compose-plugin"
    "docker-model-plugin"
    "docker-compose"
    "containerd"
    "containerd.io"
    "runc"
    "snapd"
    "cloudflared"
  ];

  rpmPackages = [
    "moby-engine"
    "moby-engine-nano"
    "moby-filesystem"
    "docker-cli"
    "docker-buildx"
    "containerd"
  ];

  debList = lib.concatStringsSep " " debPackages;
  rpmList = lib.concatStringsSep " " rpmPackages;

in {
  home.activation.systemCleanup = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    CLEANUP_PREFIX="[system-cleanup]"
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && echo "$CLEANUP_PREFIX no sudo found, skipping" && exit 0

    if command -v dpkg >/dev/null 2>&1; then
      # Debian/Ubuntu
      TO_REMOVE=""
      for pkg in ${debList}; do
        if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
          TO_REMOVE="$TO_REMOVE $pkg"
        fi
      done
      if [ -n "$TO_REMOVE" ]; then
        echo "$CLEANUP_PREFIX removing conflicting system packages:$TO_REMOVE"
        $SUDO apt-get remove -y $TO_REMOVE 2>&1 | tail -3
        $SUDO systemctl daemon-reload 2>/dev/null || true
      else
        echo "$CLEANUP_PREFIX no conflicting system packages found"
      fi

    elif command -v rpm >/dev/null 2>&1; then
      # Fedora/RHEL
      TO_REMOVE=""
      for pkg in ${rpmList}; do
        if rpm -q "$pkg" >/dev/null 2>&1; then
          TO_REMOVE="$TO_REMOVE $pkg"
        fi
      done
      if [ -n "$TO_REMOVE" ]; then
        echo "$CLEANUP_PREFIX removing conflicting system packages:$TO_REMOVE"
        $SUDO dnf remove -y $TO_REMOVE 2>&1 | tail -3
        $SUDO systemctl daemon-reload 2>/dev/null || true
      else
        echo "$CLEANUP_PREFIX no conflicting system packages found"
      fi
    fi
  '';
}
