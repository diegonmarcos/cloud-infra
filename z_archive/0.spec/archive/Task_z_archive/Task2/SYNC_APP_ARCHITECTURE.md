# sync-app.py - Unified Git & Rclone Sync Manager

**Date**: 2025-12-04
**Status**: ARCHITECTURE DESIGN
**Author**: Opus (Senior Architect)

---

## Executive Summary

A unified Python application that merges the capabilities of:
- **gcl.py** - Git repository management (clone/pull/push/status)
- **rclone.py** - Cloud storage sync (mount/bisync/one-way sync)

Into a single TUI + CLI + Flask API tool with:
- Real-time status dashboard
- Keyboard shortcuts for all operations
- Background job management
- Unified "sync" concept for both Git and Rclone

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                           sync-app.py                                        │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
│  │   CLI       │  │   TUI       │  │   API       │  │   Config    │         │
│  │   Module    │  │   Module    │  │   Module    │  │   Manager   │         │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘         │
│         │                │                │                │                 │
│         └────────────────┴────────────────┴────────────────┘                 │
│                                   │                                          │
│                    ┌──────────────┴──────────────┐                          │
│                    │        Sync Engine          │                          │
│                    └──────────────┬──────────────┘                          │
│                                   │                                          │
│         ┌─────────────────────────┼─────────────────────────┐               │
│         │                         │                         │               │
│  ┌──────┴──────┐  ┌───────────────┴───────────────┐  ┌─────┴─────┐         │
│  │ Git Manager │  │     Rclone Manager           │  │  Job Mgr   │         │
│  │             │  │                              │  │            │         │
│  │ • clone     │  │ • mount/umount               │  │ • queue    │         │
│  │ • pull      │  │ • bisync                     │  │ • status   │         │
│  │ • push      │  │ • sync (one-way)             │  │ • cancel   │         │
│  │ • fetch     │  │ • sync rules                 │  │ • history  │         │
│  │ • status    │  │                              │  │            │         │
│  └─────────────┘  └──────────────────────────────┘  └────────────┘         │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## Unified Concepts

### 1. "Repo" Abstraction

Both Git repos and Rclone sync rules are treated as "sync repos":

```python
@dataclass
class SyncRepo:
    """Unified sync repository (Git or Rclone)"""
    id: str                    # Unique identifier
    name: str                  # Display name
    type: str                  # 'git' | 'rclone_bisync' | 'rclone_sync' | 'rclone_mount'
    source: str                # Local path (Git) or source (Rclone)
    destination: str           # Remote URL (Git) or dest path/remote (Rclone)
    enabled: bool = True
    status: Optional[SyncStatus] = None
    last_sync: Optional[str] = None
    category: str = 'default'  # For grouping in TUI
```

### 2. "Status" Abstraction

Unified status for both types:

```python
@dataclass
class SyncStatus:
    """Unified status across Git and Rclone"""
    local: str           # Git: "OK"|"Uncommitted"|"X Unpushed" | Rclone: "In Sync"|"Modified"
    remote: str          # Git: "Up to Date"|"X To Pull" | Rclone: "Available"|"Offline"
    sync_state: str      # "synced"|"ahead"|"behind"|"diverged"|"syncing"|"error"
    last_activity: str   # "2m ago" | "1h ago" | etc
    ci_status: str       # Git only: "✓"|"✗"|"⟳"|"-"
    progress: float      # 0-100 for active syncs
    details: str         # Additional info
```

### 3. "Action" Abstraction

Unified actions:

| Action | Git Equivalent | Rclone Equivalent |
|--------|---------------|-------------------|
| `sync` | fetch + pull + push | bisync or sync |
| `push` | commit + push | sync to remote |
| `pull` | fetch + pull | sync to local |
| `status` | git status | check differences |
| `refresh` | fetch (no merge) | check remote state |

---

## TUI Design

### Main Dashboard Layout (80x24 terminal)

```
╔════════════════════════════════════════════════════════════════════════════╗
║                        SYNC MANAGER v1.0                      [r]efresh   ║
╠════════════════════════════════════════════════════════════════════════════╣
║ GIT REPOSITORIES                        │ STATUS          │ CI  │ LAST   ║
╟─────────────────────────────────────────┼─────────────────┼─────┼────────╢
║ [x] front-Github_profile                │ OK         │ ↑↑ │ ✓   │ 2h     ║
║ [x] front-Github_io                     │ 2 Uncommit │ OK │ ✓   │ 1d     ║
║ [x] back-System                         │ OK         │ 3↓ │ ⟳   │ 5m     ║
║ [ ] back-Algo                           │ OK         │ OK │ ✓   │ 3d     ║
║ ...                                     │            │    │     │        ║
╟─────────────────────────────────────────┴─────────────────┴─────┴────────╢
║ RCLONE SYNCS                            │ STATUS          │ DIR │ LAST   ║
╟─────────────────────────────────────────┼─────────────────┼─────┼────────╢
║ [x] Gdrive:Documents ↔ ~/Docs           │ Synced     │ ↔  │ 10m    ║
║ [x] Gdrive:Photos → ~/Photos            │ 45% ████░░ │ →  │ now    ║
║ [ ] Local:/backup ← ~/Projects          │ Modified   │ ←  │ 1h     ║
╟─────────────────────────────────────────┴─────────────────────────────────╢
║ MOUNTS                                  │ STATUS                         ║
╟─────────────────────────────────────────┼─────────────────────────────────╢
║ [●] Gdrive: → ~/Documents/Gdrive        │ MOUNTED (vfs-cache)            ║
╠════════════════════════════════════════════════════════════════════════════╣
║ [S]ync All  [P]ush  [L]pull  [F]etch  [M]ount  [C]onfig  [J]obs  [Q]uit   ║
╚════════════════════════════════════════════════════════════════════════════╝
```

### Status Column Meanings

**Git Repos:**
| Column | Values | Meaning |
|--------|--------|---------|
| Local | `OK`, `X Uncommit`, `X Unpushed` | Local working tree state |
| Remote | `OK`, `X↓ To Pull`, `Fetch Fail` | Remote state after fetch |
| CI | `✓`, `✗`, `⟳`, `-` | GitHub Actions status |
| Last | `2m`, `1h`, `3d` | Time since last push |

**Rclone Syncs:**
| Column | Values | Meaning |
|--------|--------|---------|
| Status | `Synced`, `Modified`, `XX%` | Sync state or progress |
| Dir | `↔`, `→`, `←` | Bisync, to-remote, to-local |
| Last | `2m`, `1h`, `3d` | Time since last sync |

**Mounts:**
| Column | Values | Meaning |
|--------|--------|---------|
| Status | `MOUNTED`, `NOT MOUNTED` | Mount state |

---

## Keyboard Shortcuts

### Global (any screen)
| Key | Action |
|-----|--------|
| `q` | Quit |
| `r` | Refresh all status |
| `R` | Force refresh (fetch for Git, check remote for Rclone) |
| `j/↓` | Move down |
| `k/↑` | Move up |
| `Space` | Toggle selection |
| `a` | Select all |
| `n` | Select none |
| `Tab` | Switch section (Git/Rclone/Mounts) |
| `?` | Help |

### Actions
| Key | Action | Git | Rclone |
|-----|--------|-----|--------|
| `S` | Sync selected | fetch+pull+push | bisync/sync |
| `P` | Push selected | commit+push | sync to remote |
| `L` | Pull selected | pull | sync to local |
| `F` | Fetch/Refresh | fetch only | check differences |

### Git-specific
| Key | Action |
|-----|--------|
| `c` | Commit selected with message |
| `d` | Show diff |
| `u` | Show untracked files |
| `i` | Show ignored files |
| `g` | Open GitHub Actions |

### Rclone-specific
| Key | Action |
|-----|--------|
| `m` | Mount/Unmount toggle |
| `M` | Mount menu (mode selection) |
| `b` | Force bisync resync |
| `e` | Edit sync rule |

### Navigation
| Key | Action |
|-----|--------|
| `1` | Git repos section |
| `2` | Rclone syncs section |
| `3` | Mounts section |
| `J` | Jobs/status panel |
| `C` | Configuration menu |

---

## Configuration Menu

```
╔════════════════════════════════════════════════════════════════════════════╗
║                        CONFIGURATION                                       ║
╠════════════════════════════════════════════════════════════════════════════╣
║                                                                            ║
║  ┌── GIT CONFIG ───────────────────────────────────────────────────────┐   ║
║  │ Work Directory: /home/diego/Documents/Git                           │   ║
║  │ Merge Strategy: [x] Remote (theirs)  [ ] Local (ours)               │   ║
║  │ Auto-commit msg: "fixes"                                            │   ║
║  │                                                                     │   ║
║  │ [E] Edit repos list  [A] Add repo  [R] Remove repo                  │   ║
║  └─────────────────────────────────────────────────────────────────────┘   ║
║                                                                            ║
║  ┌── RCLONE CONFIG ────────────────────────────────────────────────────┐   ║
║  │ Default Remote: Gdrive                                              │   ║
║  │ Mount Path: ~/Documents/Gdrive                                      │   ║
║  │ Bisync Base: ~/Documents/Gdrive_Syncs                               │   ║
║  │ Cache Mode: full                                                    │   ║
║  │                                                                     │   ║
║  │ [E] Edit rules  [A] Add rule  [R] Remove rule  [O] Rclone config    │   ║
║  └─────────────────────────────────────────────────────────────────────┘   ║
║                                                                            ║
║  ┌── GLOBAL CONFIG ────────────────────────────────────────────────────┐   ║
║  │ API Port: 5050                                                      │   ║
║  │ Auto-refresh: [x] Enabled (30s)                                     │   ║
║  │ Notifications: [ ] Desktop  [x] Terminal bell                       │   ║
║  └─────────────────────────────────────────────────────────────────────┘   ║
║                                                                            ║
║                              [B]ack to main                                ║
╚════════════════════════════════════════════════════════════════════════════╝
```

---

## Jobs Panel

```
╔════════════════════════════════════════════════════════════════════════════╗
║                        BACKGROUND JOBS                                     ║
╠════════════════════════════════════════════════════════════════════════════╣
║ RUNNING (2)                                                                ║
╟────────────────────────────────────────────────────────────────────────────╢
║  ▶ Gdrive:Photos → ~/Photos                           45% ████████░░░░░   ║
║    Transferred: 1.2 GB / 2.7 GB  |  Speed: 15 MB/s  |  ETA: 1m 30s        ║
║                                                                            ║
║  ▶ back-System (git sync)                             Pushing...           ║
║    2 commits to push                                                       ║
╟────────────────────────────────────────────────────────────────────────────╢
║ COMPLETED (3)                                                              ║
╟────────────────────────────────────────────────────────────────────────────╢
║  ✓ front-Github_io (git sync)                         2 min ago            ║
║  ✓ Gdrive:Documents ↔ ~/Docs                          5 min ago            ║
║  ✗ back-Algo (git push)                               10 min ago [FAILED]  ║
╟────────────────────────────────────────────────────────────────────────────╢
║                                                                            ║
║  [C]ancel running  [L]og view  [X] Clear completed  [B]ack                 ║
╚════════════════════════════════════════════════════════════════════════════╝
```

---

## CLI Interface

```bash
# TUI (default)
./sync-app.py

# Git operations
./sync-app.py git status              # Show all Git repo status
./sync-app.py git sync                # Sync all selected repos
./sync-app.py git sync front-*        # Sync repos matching pattern
./sync-app.py git push back-System    # Push specific repo
./sync-app.py git pull --all          # Pull all repos

# Rclone operations
./sync-app.py rclone status           # Show all sync rules status
./sync-app.py rclone sync             # Run all enabled sync rules
./sync-app.py rclone sync "Documents" # Run specific rule
./sync-app.py rclone mount            # Mount default remote
./sync-app.py rclone umount           # Unmount

# Unified operations
./sync-app.py sync --all              # Sync everything (Git + Rclone)
./sync-app.py status                  # Show all status
./sync-app.py jobs                    # List running/recent jobs

# API server
./sync-app.py serve                   # Start Flask API on port 5050
./sync-app.py serve --port 8080       # Custom port
```

---

## Flask API Endpoints

### Status
```
GET  /api/status                    # All status (Git + Rclone)
GET  /api/status/git                # Git repos status
GET  /api/status/rclone             # Rclone rules status
GET  /api/status/mounts             # Mount status
GET  /api/status/jobs               # Background jobs
```

### Git Operations
```
GET  /api/git/repos                 # List repos
POST /api/git/sync                  # Sync selected repos
POST /api/git/sync/<repo>           # Sync specific repo
POST /api/git/push                  # Push selected repos
POST /api/git/pull                  # Pull selected repos
POST /api/git/fetch                 # Fetch all
```

### Rclone Operations
```
GET  /api/rclone/rules              # List sync rules
POST /api/rclone/sync               # Run enabled rules
POST /api/rclone/sync/<rule>        # Run specific rule
POST /api/rclone/mount              # Mount remote
POST /api/rclone/umount             # Unmount
GET  /api/rclone/mounts             # List current mounts
```

### Jobs
```
GET  /api/jobs                      # List all jobs
GET  /api/jobs/<id>                 # Job details
POST /api/jobs/<id>/cancel          # Cancel job
DELETE /api/jobs/completed          # Clear completed
```

### Configuration
```
GET  /api/config                    # Get config
PUT  /api/config                    # Update config
GET  /api/config/git                # Git config
GET  /api/config/rclone             # Rclone config
```

---

## Configuration File Structure

```json
{
  "version": "1.0",
  "git": {
    "workdir": "/home/diego/Documents/Git",
    "merge_strategy": "theirs",
    "auto_commit_message": "fixes",
    "repos": {
      "front-Github_profile": {
        "url": "git@github.com:diegonmarcos/diegonmarcos.git",
        "enabled": true,
        "category": "public"
      },
      "front-Github_io": {
        "url": "git@github.com:diegonmarcos/diegonmarcos.github.io.git",
        "enabled": true,
        "category": "public"
      }
      // ... more repos
    }
  },
  "rclone": {
    "default_remote": "Gdrive",
    "default_mount": "~/Documents/Gdrive",
    "bisync_base": "~/Documents/Gdrive_Syncs",
    "cache_mode": "full",
    "rules": [
      {
        "name": "Documents Bisync",
        "type": "bisync",
        "source": "Gdrive:Documents",
        "destination": "~/Documents/Gdrive_Syncs/Documents",
        "conflict_resolve": "newer",
        "enabled": true
      },
      {
        "name": "Photos Backup",
        "type": "sync_to_local",
        "source": "Gdrive:Photos",
        "destination": "~/Pictures/Photos",
        "enabled": true
      }
    ],
    "mounts": [
      {
        "name": "Main Gdrive",
        "remote": "Gdrive:",
        "mountpoint": "~/Documents/Gdrive",
        "mode": "daemon"
      }
    ]
  },
  "global": {
    "api_port": 5050,
    "auto_refresh": true,
    "refresh_interval": 30,
    "notifications": {
      "desktop": false,
      "terminal_bell": true
    }
  }
}
```

---

## Default Git Repos (from gcl.sh)

```python
DEFAULT_GIT_REPOS = {
    # Public
    "front-Github_profile": "git@github.com:diegonmarcos/diegonmarcos.git",
    "front-Github_io": "git@github.com:diegonmarcos/diegonmarcos.github.io.git",
    "back-System": "git@github.com:diegonmarcos/back-System.git",
    "back-Algo": "git@github.com:diegonmarcos/back-Algo.git",
    "back-Graphic": "git@github.com:diegonmarcos/back-Graphic.git",
    "cyber-Cyberwarfare": "git@github.com:diegonmarcos/cyber-Cyberwarfare.git",
    "ops-Tooling": "git@github.com:diegonmarcos/ops-Tooling.git",
    "ops-Mylibs": "git@github.com:diegonmarcos/ops-Mylibs.git",
    "ml-MachineLearning": "git@github.com:diegonmarcos/ml-MachineLearning.git",
    "ml-DataScience": "git@github.com:diegonmarcos/ml-DataScience.git",
    "ml-Agentic": "git@github.com:diegonmarcos/ml-Agentic.git",
    # Private
    "front-Notes_md": "git@github.com:diegonmarcos/front-Notes_md.git",
    "z-lecole42": "git@github.com:diegonmarcos/lecole42.git",
    "z-dev": "git@github.com:diegonmarcos/dev.git",
}
```

---

## Auto-Refresh Behavior (from gcl.sh)

When refreshing status:

1. **Local Status Check** (fast, no network):
   - Check `git status --porcelain` for uncommitted changes
   - Check `git log @{u}..` for unpushed commits

2. **Remote Status Check** (requires fetch):
   - Run `git fetch --quiet`
   - Check `git log HEAD..@{u}` for commits to pull

3. **CI Status Check** (GitHub API):
   - Query `gh run list -R <repo> --limit 1`
   - Parse conclusion: success/failure/in_progress

4. **Last Push Time** (GitHub API):
   - Query `gh api repos/<repo>/commits/main`
   - Calculate time ago

5. **Auto-actions on refresh**:
   - If `Uncommitted` + `To Pull` → highlight as "needs attention"
   - If many repos outdated → suggest "Sync All"

---

## File Structure

```
ops-Tooling/
└── 1_GitDriveDb/
    └── sync-app/
        ├── sync-app.py           # Main entry point
        ├── sync_app/
        │   ├── __init__.py
        │   ├── config.py         # Configuration management
        │   ├── git_manager.py    # Git operations
        │   ├── rclone_manager.py # Rclone operations
        │   ├── job_manager.py    # Background jobs
        │   ├── tui.py            # TUI implementation
        │   ├── cli.py            # CLI implementation
        │   ├── api.py            # Flask API
        │   └── models.py         # Data models
        ├── config/
        │   └── sync-app.json     # Default config
        ├── requirements.txt
        └── README.md
```

---

## Implementation Order

### Phase 1: Core Infrastructure
1. Data models (`SyncRepo`, `SyncStatus`, `SyncJob`)
2. Configuration manager (load/save JSON config)
3. Job manager (background execution, status tracking)

### Phase 2: Git Manager
1. Port git operations from gcl.py
2. Status checking (local, remote, CI, last push)
3. Actions (sync, push, pull, fetch)

### Phase 3: Rclone Manager
1. Port rclone operations from rclone.py
2. Mount management
3. Sync rules management
4. Bisync support

### Phase 4: TUI
1. Main dashboard layout
2. Keyboard shortcuts
3. Navigation between sections
4. Status display with colors
5. Jobs panel

### Phase 5: CLI
1. Command parsing with argparse
2. Git subcommands
3. Rclone subcommands
4. Unified commands

### Phase 6: Flask API
1. Status endpoints
2. Action endpoints
3. Job management endpoints
4. Configuration endpoints

---

## Dependencies

```
# requirements.txt
curses        # Built-in (Linux)
flask>=2.0
requests      # For GitHub API fallback
dataclasses   # Built-in (Python 3.7+)
typing        # Built-in
pathlib       # Built-in
```

---

## Success Criteria

- [ ] TUI shows all Git repos from gcl.sh with same status columns
- [ ] TUI shows all Rclone sync rules with progress
- [ ] TUI shows mount status
- [ ] All keyboard shortcuts work as documented
- [ ] Background jobs run and report progress
- [ ] CLI matches documented interface
- [ ] API endpoints work for remote control
- [ ] Auto-refresh updates status without blocking
- [ ] Configuration persists between sessions
