# Task2: sync-app.py Implementation

**Date**: 2025-12-04
**Assignee**: Sonnet
**Supervisor**: Opus (Architect)
**Approver**: Diego (CEO)
**Status**: 🚧 READY TO START

---

## Overview

Create a unified Python application that merges **gcl.py** (Git management) and **rclone.py** (Cloud sync) into a single powerful tool with:
- TUI dashboard showing all repos and syncs with real-time status
- CLI for scripting and automation
- Flask API for remote control and integration

**Reference Documents:**
- `SYNC_APP_ARCHITECTURE.md` - Full architecture spec
- `/home/diego/Documents/Git/ops-Tooling/Git/gcl/gcl.py` - Source Git manager
- `/home/diego/Documents/Git/ops-Tooling/Rclone/rclone.py` - Source Rclone manager

**Target Location:**
`/home/diego/Documents/Git/ops-Tooling/1_GitDriveDb/sync-app/`

---

## Task 1: Project Setup & Data Models

**Priority**: HIGH
**Files to Create:**
- `sync-app/sync-app.py`
- `sync-app/sync_app/__init__.py`
- `sync-app/sync_app/models.py`
- `sync-app/requirements.txt`

### 1.1 Create Directory Structure

```bash
mkdir -p /home/diego/Documents/Git/ops-Tooling/1_GitDriveDb/sync-app/sync_app
mkdir -p /home/diego/Documents/Git/ops-Tooling/1_GitDriveDb/sync-app/config
```

### 1.2 Create Data Models (`models.py`)

```python
from dataclasses import dataclass, field
from typing import Optional, List, Dict
from datetime import datetime
from enum import Enum

class RepoType(Enum):
    GIT = "git"
    RCLONE_BISYNC = "rclone_bisync"
    RCLONE_SYNC_TO_REMOTE = "rclone_sync_to_remote"
    RCLONE_SYNC_TO_LOCAL = "rclone_sync_to_local"
    RCLONE_MOUNT = "rclone_mount"

class SyncState(Enum):
    SYNCED = "synced"
    AHEAD = "ahead"
    BEHIND = "behind"
    DIVERGED = "diverged"
    SYNCING = "syncing"
    ERROR = "error"
    UNKNOWN = "unknown"

@dataclass
class SyncStatus:
    """Unified status across Git and Rclone"""
    local: str = "Unknown"       # Git: "OK"|"Uncommitted"|"X Unpushed" | Rclone: "In Sync"|"Modified"
    remote: str = "Unknown"      # Git: "Up to Date"|"X To Pull" | Rclone: "Available"|"Offline"
    sync_state: SyncState = SyncState.UNKNOWN
    last_activity: str = ""      # "2m ago" | "1h ago" | etc
    ci_status: str = "?"         # Git only: "✓"|"✗"|"⟳"|"-"
    progress: float = 0.0        # 0-100 for active syncs
    details: str = ""            # Additional info

@dataclass
class SyncRepo:
    """Unified sync repository (Git or Rclone)"""
    id: str
    name: str
    type: RepoType
    source: str                  # Local path (Git) or source (Rclone)
    destination: str             # Remote URL (Git) or dest path/remote (Rclone)
    enabled: bool = True
    status: Optional[SyncStatus] = None
    last_sync: Optional[str] = None
    category: str = "default"
    config: Dict = field(default_factory=dict)  # Extra config (conflict_resolve, etc)

@dataclass
class SyncJob:
    """Background sync job"""
    job_id: str
    repo_id: str
    repo_name: str
    action: str                  # "sync"|"push"|"pull"|"mount"|"bisync"
    status: str                  # "running"|"completed"|"failed"|"cancelled"
    started: str
    ended: Optional[str] = None
    pid: Optional[int] = None
    log_file: Optional[str] = None
    progress: float = 0.0
    details: str = ""
    error: Optional[str] = None
```

### 1.3 Create requirements.txt

```
flask>=2.0
flask-cors
```

### 1.4 Create Main Entry Point (`sync-app.py`)

```python
#!/usr/bin/env python3
"""
sync-app.py - Unified Git & Rclone Sync Manager
TUI + CLI + Flask API for managing all sync operations
"""

import sys
from sync_app.cli import main as cli_main

if __name__ == '__main__':
    cli_main()
```

---

## Task 2: Configuration Manager

**Priority**: HIGH
**Files:** `sync-app/sync_app/config.py`

### 2.1 Implement Config Manager

```python
import json
from pathlib import Path
from typing import Dict, List, Optional
from dataclasses import asdict
from .models import SyncRepo, RepoType

# Default Git repos from gcl.sh
DEFAULT_GIT_REPOS = {
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
    "front-Notes_md": "git@github.com:diegonmarcos/front-Notes_md.git",
    "z-lecole42": "git@github.com:diegonmarcos/lecole42.git",
    "z-dev": "git@github.com:diegonmarcos/dev.git",
}

class ConfigManager:
    def __init__(self, config_path: Optional[Path] = None):
        self.config_dir = Path.home() / '.config' / 'sync-app'
        self.config_file = config_path or (self.config_dir / 'config.json')
        self.config_dir.mkdir(parents=True, exist_ok=True)
        self._config = self._load_or_create()

    def _load_or_create(self) -> Dict:
        if self.config_file.exists():
            with open(self.config_file) as f:
                return json.load(f)
        return self._create_default_config()

    def _create_default_config(self) -> Dict:
        config = {
            "version": "1.0",
            "git": {
                "workdir": "/home/diego/Documents/Git",
                "merge_strategy": "theirs",
                "auto_commit_message": "fixes",
                "repos": {name: {"url": url, "enabled": True, "category": "default"}
                         for name, url in DEFAULT_GIT_REPOS.items()}
            },
            "rclone": {
                "default_remote": "Gdrive",
                "default_mount": str(Path.home() / "Documents/Gdrive"),
                "bisync_base": str(Path.home() / "Documents/Gdrive_Syncs"),
                "cache_mode": "full",
                "rules": [],
                "mounts": []
            },
            "global": {
                "api_port": 5050,
                "auto_refresh": True,
                "refresh_interval": 30
            }
        }
        self.save(config)
        return config

    def save(self, config: Optional[Dict] = None):
        if config:
            self._config = config
        with open(self.config_file, 'w') as f:
            json.dump(self._config, f, indent=2)

    @property
    def git_workdir(self) -> str:
        return self._config["git"]["workdir"]

    @property
    def git_repos(self) -> Dict:
        return self._config["git"]["repos"]

    @property
    def rclone_rules(self) -> List:
        return self._config["rclone"]["rules"]

    @property
    def rclone_mounts(self) -> List:
        return self._config["rclone"]["mounts"]

    def get_all_repos(self) -> List[SyncRepo]:
        """Get all repos (Git + Rclone) as unified SyncRepo objects"""
        repos = []

        # Git repos
        for name, info in self.git_repos.items():
            repos.append(SyncRepo(
                id=f"git_{name}",
                name=name,
                type=RepoType.GIT,
                source=str(Path(self.git_workdir) / name),
                destination=info["url"],
                enabled=info.get("enabled", True),
                category=info.get("category", "git")
            ))

        # Rclone rules
        for rule in self.rclone_rules:
            repo_type = {
                "bisync": RepoType.RCLONE_BISYNC,
                "sync_to_remote": RepoType.RCLONE_SYNC_TO_REMOTE,
                "sync_to_local": RepoType.RCLONE_SYNC_TO_LOCAL
            }.get(rule.get("type", "bisync"), RepoType.RCLONE_BISYNC)

            repos.append(SyncRepo(
                id=f"rclone_{rule['name']}",
                name=rule["name"],
                type=repo_type,
                source=rule["source"],
                destination=rule["destination"],
                enabled=rule.get("enabled", True),
                category="rclone",
                config=rule
            ))

        return repos
```

---

## Task 3: Git Manager

**Priority**: HIGH
**Files:** `sync-app/sync_app/git_manager.py`

Port all Git operations from `gcl.py`:

### Key Functions to Implement:
- `run_git(repo_dir, *args)` - Execute git commands
- `get_repo_local_status(repo_dir)` - Check uncommitted/unpushed
- `get_repo_remote_status(repo_dir, do_fetch)` - Check commits to pull
- `get_repo_ci_status(repo_name)` - GitHub Actions status
- `get_repo_push_status(repo_name)` - Last push time
- `sync_repo(repo_dir, strategy)` - Full sync operation
- `push_repo(repo_dir)` - Commit and push
- `pull_repo(repo_dir, strategy)` - Pull with strategy
- `fetch_repo(repo_dir)` - Fetch only

### Integration Points:
- Return `SyncStatus` objects from status functions
- Support `SyncJob` for background operations
- Emit progress updates for TUI

---

## Task 4: Rclone Manager

**Priority**: HIGH
**Files:** `sync-app/sync_app/rclone_manager.py`

Port all Rclone operations from `rclone.py`:

### Key Functions to Implement:
- `check_rclone_installed()` - Verify rclone is available
- `get_mount_status(mountpoint)` - Check if path is mounted
- `mount_remote(remote, local_path, mode)` - Mount operation
- `umount_remote(local_path, force)` - Unmount operation
- `bisync(path1, path2, dry_run, resync)` - Bidirectional sync
- `sync_one_direction(source, dest, dry_run, delete)` - One-way sync
- `run_sync_rule(rule, dry_run)` - Execute a sync rule
- `get_sync_status(rule)` - Check differences

### Integration Points:
- Return `SyncStatus` objects
- Support background jobs with progress parsing
- Parse rclone output for progress (%, speed, ETA)

---

## Task 5: Job Manager

**Priority**: MEDIUM
**Files:** `sync-app/sync_app/job_manager.py`

### Key Functions:
- `start_job(repo_id, action, callback)` - Start background job
- `get_running_jobs()` - List running jobs
- `get_job_status(job_id)` - Get job details
- `cancel_job(job_id)` - Cancel running job
- `get_job_progress(job)` - Parse log for progress
- `clear_completed_jobs()` - Clean up history

### Features:
- Store jobs in `~/.config/sync-app/jobs.json`
- Keep last 50 jobs in history
- Parse log files for real-time progress
- Support for both Git and Rclone jobs

---

## Task 6: TUI Implementation

**Priority**: HIGH
**Files:** `sync-app/sync_app/tui.py`

### 6.1 Main Dashboard

Implement the TUI layout from architecture doc:
- Header with title and refresh indicator
- Git repos section with status columns (Local, Remote, CI, Last)
- Rclone syncs section with status (Status, Dir, Last)
- Mounts section
- Keybindings footer

### 6.2 Keyboard Shortcuts

Implement all shortcuts from architecture doc:
- Navigation: j/k/↑/↓, Tab, 1/2/3
- Selection: Space, a, n
- Actions: S, P, L, F, m, M
- Panels: J (jobs), C (config), ? (help)

### 6.3 Status Display

Format status columns with colors:
- Green for OK/synced
- Yellow for pending/warning
- Red for errors/failures
- Cyan for progress

### 6.4 Progress Display

For active syncs, show:
- Progress bar: `[████████░░░░░] 65%`
- Transfer info: `1.2 GB / 2.0 GB`
- Speed and ETA: `15 MB/s | ETA 2m`

---

## Task 7: CLI Implementation

**Priority**: MEDIUM
**Files:** `sync-app/sync_app/cli.py`

### Command Structure:

```python
import argparse

def main():
    parser = argparse.ArgumentParser(prog='sync-app')
    subparsers = parser.add_subparsers(dest='command')

    # No command = TUI
    # git subcommands
    git_parser = subparsers.add_parser('git')
    git_sub = git_parser.add_subparsers(dest='git_cmd')
    git_sub.add_parser('status')
    git_sub.add_parser('sync')
    git_sub.add_parser('push')
    git_sub.add_parser('pull')
    git_sub.add_parser('fetch')

    # rclone subcommands
    rclone_parser = subparsers.add_parser('rclone')
    rclone_sub = rclone_parser.add_subparsers(dest='rclone_cmd')
    rclone_sub.add_parser('status')
    rclone_sub.add_parser('sync')
    rclone_sub.add_parser('mount')
    rclone_sub.add_parser('umount')

    # unified commands
    subparsers.add_parser('status')
    subparsers.add_parser('sync')
    subparsers.add_parser('jobs')

    # serve (API)
    serve_parser = subparsers.add_parser('serve')
    serve_parser.add_argument('--port', type=int, default=5050)

    args = parser.parse_args()

    if args.command is None:
        # Launch TUI
        from .tui import TUI
        tui = TUI()
        tui.run()
    elif args.command == 'serve':
        from .api import run_api
        run_api(port=args.port)
    # ... handle other commands
```

---

## Task 8: Flask API

**Priority**: LOW
**Files:** `sync-app/sync_app/api.py`

### Implement Endpoints:

```python
from flask import Flask, jsonify, request
from flask_cors import CORS

app = Flask(__name__)
CORS(app)

@app.route('/api/status')
def get_status():
    """Get all repos status"""
    pass

@app.route('/api/git/repos')
def get_git_repos():
    """List Git repos with status"""
    pass

@app.route('/api/git/sync', methods=['POST'])
def git_sync():
    """Sync selected Git repos"""
    pass

@app.route('/api/rclone/rules')
def get_rclone_rules():
    """List Rclone sync rules"""
    pass

@app.route('/api/rclone/sync', methods=['POST'])
def rclone_sync():
    """Run Rclone sync rules"""
    pass

@app.route('/api/jobs')
def get_jobs():
    """List background jobs"""
    pass

def run_api(port=5050):
    app.run(host='0.0.0.0', port=port)
```

---

## Testing Checklist

### Core Functions
- [ ] Config loads/saves correctly
- [ ] Default Git repos are populated
- [ ] Git status detection works
- [ ] Git sync/push/pull operations work
- [ ] Rclone mount/umount works
- [ ] Rclone bisync works
- [ ] Background jobs run and track progress

### TUI
- [ ] Dashboard displays all repos
- [ ] Status columns show correct values
- [ ] Keyboard navigation works
- [ ] Action shortcuts trigger operations
- [ ] Jobs panel shows running/completed

### CLI
- [ ] `./sync-app.py` launches TUI
- [ ] `./sync-app.py status` shows status
- [ ] `./sync-app.py git sync` syncs Git repos
- [ ] `./sync-app.py rclone mount` mounts
- [ ] `./sync-app.py serve` starts API

### API
- [ ] `/api/status` returns JSON
- [ ] `/api/git/sync` triggers sync
- [ ] `/api/jobs` lists jobs

---

## Commit Message Template

```
feat(sync-app): unified Git & Rclone sync manager

- Merge gcl.py and rclone.py into single application
- TUI dashboard with real-time status for all repos
- Keyboard shortcuts for all operations
- CLI for scripting and automation
- Flask API for remote control
- Background job management with progress tracking
- Unified "repo" abstraction for Git and Rclone

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
```
