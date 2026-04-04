# Surface Pro 8 Specifications

## Overview
| Property | Value |
|----------|-------|
| **Device** | Microsoft Surface Pro 8 |
| **Type** | Local Workstation |
| **Status** | Active |

## Hardware
| Component | Specification |
|-----------|---------------|
| **CPU** | Intel Core i7-1185G7 @ 3.00GHz |
| **RAM** | 16 GB |
| **Storage** | 256 GB NVMe SSD |
| **Display** | 13" 2880x1920 PixelSense |
| **GPU** | Intel Iris Xe Graphics |

## Current OS
| Property | Value |
|----------|-------|
| **Distribution** | Linux (Surface Kernel) |
| **Kernel** | 6.17.1-surface-2 |
| **Desktop** | KDE Plasma / Wayland |

## Target Migration
| Property | Value |
|----------|-------|
| **Host OS** | Fedora 41+ (Silverblue/KDE) |
| **Dev Container** | Distrobox (Arch Linux) |
| **Python Isolation** | Poetry per-project venvs |
| **Encryption** | LUKS2 + Btrfs |

## Partition Plan
| Partition | Size | Type | Mount |
|-----------|------|------|-------|
| ESP | 512MB | EFI | /boot/efi |
| Windows | 60GB | NTFS | - |
| Boot | 1GB | ext4 | /boot |
| LUKS Root | REST | LUKS2→Btrfs | / |

## Btrfs Subvolumes
```
@           →  /
@home       →  /home
@var        →  /var
@snapshots  →  /.snapshots
@containers →  /var/lib/containers
```

## Key Features
- Surface Kernel (linux-surface) for hardware support
- Secure Boot with MOK enrollment
- Full disk encryption (LUKS2 with Argon2id)
- Flatpak for GUI apps
- Distrobox for dev environment isolation
- Poetry for Python project isolation

## Development Tools
- Fish + Zsh + Starship shells
- Claude Code CLI
- VSCode with extensions
- Node.js, Python, Rust toolchains
- Docker/Podman

## Sync Integration
- Syncthing connected to cloud servers
- Git repositories synced
