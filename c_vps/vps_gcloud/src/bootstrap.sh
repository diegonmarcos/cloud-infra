#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ GCP VM bootstrap — runs once on first boot via metadata          ║
# ║ Source: c_vps/vps_gcloud/src/bootstrap.sh                        ║
# ║ Wired:  c_vps/vps_gcloud/src/main.tf metadata.startup-script     ║
# ║                                                                  ║
# ║ Brings a bare Fedora 42 cloud image to a state where             ║
# ║ b_infra/nixhm-sudo-<vm>/build.sh ship JustWorks.                 ║
# ║                                                                  ║
# ║ Idempotent: only runs steps that haven't completed.              ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eu

MARKER=/var/lib/cloud-bootstrap.done
[ -f "$MARKER" ] && { echo "[bootstrap] already done — skipping"; exit 0; }

log() { echo "[bootstrap] $1" | systemd-cat -t cloud-bootstrap -p info; echo "[bootstrap] $1"; }

# ── 1. Grow root partition to full disk ─────────────────────────────
# Fedora cloud image ships with 9 GB partition; the underlying disk is
# whatever Terraform requested (we want 30 GB). growpart + resize claims
# the rest. cloud-utils-growpart is needed.
log "1/8 grow root partition"
dnf install -y cloud-utils-growpart e2fsprogs btrfs-progs >/dev/null 2>&1 || true
ROOT_DEV=$(findmnt -no SOURCE /)
ROOT_DISK=$(lsblk -no PKNAME "$ROOT_DEV" 2>/dev/null | head -1)
ROOT_PART=$(echo "$ROOT_DEV" | grep -oE '[0-9]+$' | head -1)
[ -n "$ROOT_DISK" ] && [ -n "$ROOT_PART" ] && growpart "/dev/$ROOT_DISK" "$ROOT_PART" 2>/dev/null || true
case "$(findmnt -no FSTYPE /)" in
  btrfs) btrfs filesystem resize max / 2>/dev/null || true ;;
  ext4)  resize2fs "$ROOT_DEV" 2>/dev/null || true ;;
  xfs)   xfs_growfs / 2>/dev/null || true ;;
esac

# ── 2. Disable SELinux (kernel arg + persist) ───────────────────────
# HM activation bind-mounts host / into a container; SELinux MAC blocks
# the mount writes. Match arch-1's posture (selinux=disabled).
log "2/8 disable SELinux"
grubby --update-kernel ALL --args selinux=0 >/dev/null 2>&1 || true
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config 2>/dev/null || true

# ── 3. Install Docker (moby-engine) and dependencies ────────────────
# Fedora's moby-engine ships /usr/bin/containerd-shim-runc-v2 with a newer
# shim ABI than the nix-installed dockerd HM later deploys. Mismatch breaks
# `docker run` with "unsupported shim version (3): not implemented".
# We install moby-engine for the daemon binaries (so VM has docker pre-HM),
# but mask the system shim so HM's dockerd uses its own bundled shim from
# /nix/store/...-docker-containerd-*/bin/containerd-shim-runc-v2 via the
# Environment=PATH= injected by HM's container/init.nix module.
log "3/8 install docker + activation deps"
dnf install -y moby-engine gawk findutils which curl >/dev/null 2>&1
# Remove Fedora's shim binary so PATH lookup falls through to HM's nix-store
# version once HM activation has run. Idempotent: -f no-op when missing.
rm -f /usr/bin/containerd-shim-runc-v2
systemctl enable --now docker

# ── 4. Add diego user to docker group ───────────────────────────────
log "4/8 add diego to docker group"
usermod -aG docker diego 2>/dev/null || true

# ── 5. Install Determinate Nix (single-user-friendly daemon mode) ──
# Vendored locally in the build (next to bootstrap.sh) so we don't pipe
# from internet. The HM image bundles its own nix store; this primes
# nix-daemon + /nix layout so HM activation registers paths cleanly.
log "5/8 install Determinate Nix"
if [ ! -e /nix/var/nix/profiles/default ]; then
  if [ -f /var/lib/cloud/instance/scripts/det-nix-install.sh ]; then
    sh /var/lib/cloud/instance/scripts/det-nix-install.sh install linux \
      --no-confirm --determinate >/dev/null 2>&1 || true
  else
    curl --proto '=https' --tlsv1.2 -sSfL https://install.determinate.systems/nix \
      | sh -s -- install linux --no-confirm --determinate >/dev/null 2>&1 || true
  fi
fi
# Hand /nix to diego so HM activation (run as user) can mutate locks.
chown -R diego:diego /nix/store /nix/var 2>/dev/null || true

# ── 6. Login Docker to GHCR for ghcr.io/diegonmarcos pulls ──────────
# Token comes from VM-side sops-encrypted metadata file dropped by the
# secrets pipeline; bootstrap reads it once, configures docker, deletes it.
log "6/8 GHCR login"
if [ -f /var/lib/cloud/instance/scripts/ghcr-token ]; then
  cat /var/lib/cloud/instance/scripts/ghcr-token \
    | docker login ghcr.io -u diegonmarcos --password-stdin >/dev/null 2>&1 || true
  install -d -m 700 -o diego -g diego /home/diego/.docker
  cp /root/.docker/config.json /home/diego/.docker/config.json 2>/dev/null || true
  chown diego:diego /home/diego/.docker/config.json 2>/dev/null || true
  shred -u /var/lib/cloud/instance/scripts/ghcr-token 2>/dev/null || true
fi

# ── 7. Clear default Fedora dotfiles that block HM activation ───────
# HM refuses to write over existing files; Fedora's default .bashrc and
# .bash_profile would otherwise trip "Existing file in the way" on first
# `home-manager switch`. Move them aside; HM rewrites cleanly.
log "7/8 stash default dotfiles"
sudo -u diego mkdir -p /home/diego/.bak-pre-hm 2>/dev/null || true
for f in .bashrc .bash_profile .profile; do
  [ -f "/home/diego/$f" ] && mv "/home/diego/$f" "/home/diego/.bak-pre-hm/$f" 2>/dev/null || true
done

# ── 8. Mark complete ────────────────────────────────────────────────
log "8/8 done — VM ready for build.sh ship"
touch "$MARKER"

# Reboot ONCE to apply selinux=0 + grow filesystem cleanly, only on first
# boot when SELinux was active.
if [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
  log "rebooting to apply SELinux=disabled"
  systemctl reboot
fi
