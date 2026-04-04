#!/bin/bash
# Optimized APT Package Installation Script
# This script installs only manually-installed packages.
# Dependencies will be automatically installed by apt.

set -e  # Exit on error

echo "Installing ${len(manual_packages)} manual packages..."
echo "Dependencies will be installed automatically."
echo ""

# Update package list
sudo apt update

# Install all manual packages
sudo apt install -y \
  apt-transport-https \
  auditd \
  base-files \
  bash \
  bash-completion \
  bear \
  brave-browser \
  bsdutils \
  btrfs-progs \
  build-essential \
  clang \
  clang-tidy \
  cmake \
  code \
  cracklib-runtime \
  cryptsetup \
  curl \
  dash \
  diffutils \
  discord \
  dmeventd \
  dmraid \
  docker.io \
  doxygen \
  doxygen-gui \
  efibootmgr \
  fcitx5-chinese-addons \
  fcitx5-frontend-all \
  fcitx5-material-color \
  filelight \
  findutils \
  fish \
  freeglut3-dev \
  g++ \
  gcc \
  gdal-bin \
  gir1.2-ayatanaappindicator3-0.1 \
  gnome-power-manager \
  gnome-shell-extension-appindicator \
  gobjc \
  google-chrome-stable \
  graphviz \
  grep \
  grsync \
  grub-efi-amd64-bin \
  grub-efi-amd64-signed \
  grub-gfxpayload-lists \
  grub-pc \
  grub-pc-bin \
  grub2-common \
  gzip \
  hostname \
  hyphen-en-ca \
  hyphen-fi \
  hyphen-ga \
  hyphen-id \
  init \
  iptsd \
  jekyll \
  jfsutils \
  kde-config-fcitx5 \
  keyutils \
  konqueror \
  kpartx \
  kpartx-boot \
  kubuntu-desktop \
  kubuntu-wallpapers \
  language-pack-en \
  language-pack-en-base \
  language-pack-gnome-en \
  libagg-dev \
  libaio1t64 \
  libayatana-appindicator3-1 \
  libbsd-dev \
  libclang-dev \
  libcrack2 \
  libdevmapper-event1.02.1 \
  libdmraid1.0.0.rc16 \
  libfreetype-dev \
  libgdal-dev \
  libgl1-mesa-dev \
  libglfw3-dev \
  libglu1-mesa-dev \
  libinih1 \
  liblvm2cmd2.03 \
  liblzf1 \
  libncurses-dev \
  libpotrace-dev \
  libpq-dev \
  libpwquality-common \
  libpwquality1 \
  libqt6help6 \
  libqt6printsupport6t64 \
  libqt6statemachine6 \
  libqt6xml6t64 \
  libreiserfscore0t64 \
  libudev-dev \
  liburcu8t64 \
  libwacom-surface \
  libx11-dev \
  libxext-dev \
  libxrandr-dev \
  libyaml-cpp0.8 \
  linux-generic \
  linux-headers-surface \
  linux-image-surface \
  linux-surface-secureboot-mok \
  linux-tools-common \
  linux-tools-generic \
  lldb \
  login \
  lvm2 \
  make \
  mokutil \
  ncurses-base \
  ncurses-bin \
  nodejs \
  npm \
  obsidian \
  openjdk-21-jdk \
  openoffice.org-hyphenation \
  pinhole \
  pipx \
  potrace \
  proton-vpn-gnome-desktop \
  protonvpn-stable-release \
  python3-dev \
  python3-pip \
  python3-setuptools \
  python3-venv \
  python3-wheel \
  rclone \
  reiserfsprogs \
  rsync \
  ruby \
  ruby-full \
  scribus \
  shim-signed \
  slack-desktop \
  snapd \
  stacer \
  systemd-oomd \
  texlive \
  thin-provisioning-tools \
  ubuntu-minimal \
  ubuntu-standard \
  valgrind \
  virt-manager \
  virtualbox-7.0 \
  wamerican \
  wbritish \
  wmctrl \
  xdotool \
  xfsprogs \
  xorg \
  zlib1g-dev \
  zsh

echo ""
echo "Installation complete!"
echo "Total manual packages installed: 157"
