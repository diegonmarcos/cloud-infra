# Surface Pro 8 Migration Scripts

Scripts to migrate from Ubuntu to Fedora + Distrobox (Arch) with Poetry Python isolation.

## Architecture Summary

```
┌─────────────────────────────────────────────────────────┐
│                    SURFACE PRO 8                         │
├──────────────┬──────────────────────────────────────────┤
│  Windows 11  │      LUKS2 Encrypted Partition           │
│   (~60GB)    │                                          │
│              │   ┌──────────────────────────────────┐   │
│  - Camera    │   │       FEDORA HOST (Minimal)      │   │
│  - Webcalls  │   │                                  │   │
│              │   │  ┌────────────────────────────┐  │   │
│              │   │  │   DISTROBOX: ARCH LINUX    │  │   │
│              │   │  │                            │  │   │
│              │   │  │  ┌──────────────────────┐  │  │   │
│              │   │  │  │  POETRY VENVS        │  │  │   │
│              │   │  │  │  (Per-Project)       │  │  │   │
│              │   │  │  └──────────────────────┘  │  │   │
│              │   │  └────────────────────────────┘  │   │
│              │   └──────────────────────────────────┘   │
└──────────────┴──────────────────────────────────────────┘
```

## Isolation Layers

| Layer | Purpose | Technology |
|-------|---------|------------|
| 1 | Disk Encryption | LUKS2 (Argon2id) |
| 2 | Secure Boot | linux-surface signed kernel |
| 3 | Host Isolation | Fedora (minimal install) |
| 4 | Dev Isolation | Distrobox + Podman |
| 5 | Python Isolation | Poetry virtualenvs |
| 6 | App Isolation | Flatpak sandboxing |

## Script Execution Order

### Phase 1: Pre-Migration (On Ubuntu)

```bash
# Backup everything before starting
./00-pre-migration-backup.sh /media/backup/surfacepro8
```

### Phase 2: Fedora Installation

1. Boot Fedora KDE ISO
2. Shrink Windows to 60GB (or reinstall minimal)
3. Create partitions:
   - `/boot/efi` - 512MB EFI (if not exists)
   - `/boot` - 1GB ext4
   - `/` - REST, LUKS2 encrypted, Btrfs
4. Complete installation with encryption enabled

### Phase 3: Host Setup (On Fedora)

```bash
# 1. Setup Fedora host with Surface drivers
./01-fedora-host-setup.sh
sudo reboot  # Select Surface kernel

# 2. Install sandboxed GUI apps
./02-install-flatpak-apps.sh

# 3. Create development container
./03-create-arch-dev.sh
```

### Phase 4: Container Setup (Inside Distrobox)

```bash
# Enter container
distrobox enter arch-dev

# Run these inside the container:
./04-install-dev-tools.sh
./05-install-python-env.sh
./06-configure-shells.sh
./07-install-vscode-extensions.sh
```

### Phase 5: Data Restoration

```bash
# Can be run from host or container
./08-restore-data.sh /media/backup/surfacepro8
```

## Configuration Files

Located in `config/`:

| File | Purpose |
|------|---------|
| `arch-packages.yaml` | Arch Linux packages for Distrobox |
| `flatpak-apps.yaml` | Sandboxed GUI apps for Fedora |
| `fedora-packages.yaml` | Minimal Fedora host packages |
| `python-packages.yaml` | Poetry project dependencies |
| `vscode-extensions.yaml` | VS Code extensions |

## Daily Workflow

```bash
# Start development
distrobox enter arch-dev

# Navigate to project
cd ~/Documents/Git/my-project

# Activate Python environment
poetry shell
# or
poetry run python script.py

# Run VS Code
code .

# Exit container
exit
```

## Quick Reference

### Distrobox Commands
```bash
distrobox enter arch-dev          # Enter container
distrobox stop arch-dev           # Stop container
distrobox rm arch-dev             # Remove container
distrobox list                    # List containers
distrobox-export --app code       # Export app to host
```

### Poetry Commands
```bash
poetry new myproject              # New project
poetry init                       # Init in existing dir
poetry add package                # Add dependency
poetry add --group dev pytest     # Add dev dependency
poetry install                    # Install all deps
poetry shell                      # Activate venv
poetry run python script.py       # Run in venv
poetry update                     # Update deps
poetry lock                       # Update lock file
```

### Btrfs Snapshots
```bash
sudo snapper create -d "Before update"    # Create snapshot
sudo snapper list                         # List snapshots
sudo snapper undochange 1..2              # Rollback changes
```

## Troubleshooting

### Surface Pro 8

```bash
# Touch not working
sudo systemctl restart iptsd

# Check Surface kernel
uname -r  # Should show "surface"

# Check secure boot
mokutil --sb-state
```

### Container Issues

```bash
# Reset container
distrobox rm -f arch-dev
./03-create-arch-dev.sh

# GUI apps not displaying
xhost +local:

# Check podman
podman system info
```

### Poetry Issues

```bash
# Wrong Python version
poetry env use python3.12

# Recreate venv
rm -rf .venv
poetry install

# Clear cache
poetry cache clear . --all
```

## Files Structure After Migration

```
$HOME/
├── .config/
│   ├── fish/config.fish
│   ├── starship.toml
│   └── Code/User/settings.json
├── .ssh/
├── .gnupg/
├── Documents/
│   └── Git/              # Your repositories
├── Projects/             # Poetry projects
│   └── myproject/
│       ├── pyproject.toml
│       ├── poetry.lock
│       └── .venv/
└── .local/bin/           # pipx binaries
```
