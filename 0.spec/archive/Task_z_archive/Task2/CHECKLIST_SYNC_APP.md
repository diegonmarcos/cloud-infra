# Task2: sync-app.py Implementation Checklist

**Task**: Unified Git & Rclone Sync Manager
**Started**: 2025-12-04
**Assignee**: Sonnet
**Supervisor**: Opus
**Status**: 🚧 READY TO START

---

## Quick Status

| Phase | Status | Progress |
|-------|--------|----------|
| Task 1: Project Setup | ⏳ Pending | 0% |
| Task 2: Config Manager | ⏳ Pending | 0% |
| Task 3: Git Manager | ⏳ Pending | 0% |
| Task 4: Rclone Manager | ⏳ Pending | 0% |
| Task 5: Job Manager | ⏳ Pending | 0% |
| Task 6: TUI | ⏳ Pending | 0% |
| Task 7: CLI | ⏳ Pending | 0% |
| Task 8: Flask API | ⏳ Pending | 0% |
| **OVERALL** | **⏳ Pending** | **0%** |

---

## Task 1: Project Setup & Data Models

### 1.1 Directory Structure
- [ ] Create `sync-app/` directory
- [ ] Create `sync-app/sync_app/` package directory
- [ ] Create `sync-app/config/` directory

### 1.2 Data Models (`models.py`)
- [ ] Create `RepoType` enum
- [ ] Create `SyncState` enum
- [ ] Create `SyncStatus` dataclass
- [ ] Create `SyncRepo` dataclass
- [ ] Create `SyncJob` dataclass

### 1.3 Project Files
- [ ] Create `requirements.txt`
- [ ] Create `sync-app.py` entry point
- [ ] Create `sync_app/__init__.py`
- [ ] Make `sync-app.py` executable

**Task 1 Status**: ⏳ Pending

---

## Task 2: Configuration Manager

### 2.1 Core Config
- [ ] Define DEFAULT_GIT_REPOS dict (14 repos from gcl.sh)
- [ ] Create ConfigManager class
- [ ] Implement `_load_or_create()` method
- [ ] Implement `_create_default_config()` method
- [ ] Implement `save()` method

### 2.2 Config Properties
- [ ] `git_workdir` property
- [ ] `git_repos` property
- [ ] `rclone_rules` property
- [ ] `rclone_mounts` property
- [ ] `api_port` property

### 2.3 Config Methods
- [ ] `get_all_repos()` - Returns List[SyncRepo]
- [ ] `add_git_repo(name, url)` - Add new Git repo
- [ ] `add_rclone_rule(rule)` - Add new Rclone rule
- [ ] `update_repo(id, changes)` - Update repo config
- [ ] `delete_repo(id)` - Remove repo

### 2.4 Config File
- [ ] Config saved to `~/.config/sync-app/config.json`
- [ ] Default config created on first run
- [ ] Config validated on load

**Task 2 Status**: ⏳ Pending

---

## Task 3: Git Manager

### 3.1 Git Operations (from gcl.py)
- [ ] `run_git(repo_dir, *args)` - Execute git commands
- [ ] `get_repo_local_status(repo_dir)` - Check uncommitted/unpushed
- [ ] `get_repo_remote_status(repo_dir, do_fetch)` - Check to-pull
- [ ] `format_age(timestamp)` - Format time ago

### 3.2 GitHub Integration
- [ ] `get_repo_ci_status(repo_name)` - GitHub Actions status
- [ ] `get_repo_push_status(repo_name)` - Last push time
- [ ] Parse `gh run list` output
- [ ] Parse `gh api repos/*/commits/main` output

### 3.3 Git Actions
- [ ] `sync_repo(repo_dir, strategy)` - Full sync (commit+fetch+pull+push)
- [ ] `push_repo(repo_dir)` - Commit and push
- [ ] `pull_repo(repo_dir, strategy)` - Pull with merge strategy
- [ ] `fetch_repo(repo_dir)` - Fetch only
- [ ] `clone_repo(url, target)` - Clone new repo

### 3.4 Status Integration
- [ ] Return `SyncStatus` from all status functions
- [ ] Calculate `SyncState` (synced/ahead/behind/diverged)
- [ ] Parse git output for progress

**Task 3 Status**: ⏳ Pending

---

## Task 4: Rclone Manager

### 4.1 Rclone Operations (from rclone.py)
- [ ] `check_rclone_installed()` - Verify rclone available
- [ ] `get_rclone_remotes()` - List configured remotes
- [ ] `list_remote_folders(remote)` - List folders in remote

### 4.2 Mount Operations
- [ ] `get_mount_status(mountpoint)` - Check if mounted
- [ ] `get_all_mounts()` - List current rclone mounts
- [ ] `mount_remote(remote, local, mode)` - Mount operation
- [ ] `umount_remote(local, force)` - Unmount operation
- [ ] `reset_mount(remote, local)` - Remount

### 4.3 Sync Operations
- [ ] `bisync(path1, path2, dry_run, resync)` - Bidirectional sync
- [ ] `sync_one_direction(src, dest, dry_run, delete)` - One-way sync
- [ ] `run_sync_rule(rule, dry_run)` - Execute sync rule
- [ ] Check for differences before sync

### 4.4 Status Integration
- [ ] Return `SyncStatus` from status functions
- [ ] Parse rclone log for progress (%, speed, ETA)
- [ ] Support background execution

**Task 4 Status**: ⏳ Pending

---

## Task 5: Job Manager

### 5.1 Job Storage
- [ ] Create `jobs.json` storage file
- [ ] `load_jobs()` - Load job history
- [ ] `save_jobs(jobs)` - Save job history
- [ ] Keep max 50 jobs in history

### 5.2 Job Operations
- [ ] `start_job(repo_id, action)` - Start background job
- [ ] `generate_job_id()` - Create unique job ID
- [ ] `get_running_jobs()` - List active jobs
- [ ] `get_job_status(job_id)` - Get specific job
- [ ] `cancel_job(job_id)` - Cancel running job
- [ ] `clear_completed_jobs()` - Clean history

### 5.3 Progress Tracking
- [ ] Parse Git output for progress
- [ ] Parse Rclone log for progress
- [ ] Update job status in real-time
- [ ] Detect job completion/failure

**Task 5 Status**: ⏳ Pending

---

## Task 6: TUI Implementation

### 6.1 Main Dashboard Layout
- [ ] Header with title and refresh indicator
- [ ] Git repos section (scrollable)
- [ ] Rclone syncs section
- [ ] Mounts section
- [ ] Keybindings footer

### 6.2 Status Columns - Git
- [ ] Name column
- [ ] Local status (OK/Uncommitted/Unpushed)
- [ ] Remote status (Up to Date/To Pull)
- [ ] CI status (✓/✗/⟳/-)
- [ ] Last push time

### 6.3 Status Columns - Rclone
- [ ] Name column
- [ ] Source → Dest display
- [ ] Status (Synced/Modified/Progress%)
- [ ] Direction icon (↔/→/←)
- [ ] Last sync time

### 6.4 Keyboard Navigation
- [ ] j/k or ↑/↓ - Move cursor
- [ ] Tab - Switch sections
- [ ] 1/2/3 - Jump to section
- [ ] Space - Toggle selection
- [ ] a - Select all
- [ ] n - Select none

### 6.5 Action Shortcuts
- [ ] S - Sync selected
- [ ] P - Push selected
- [ ] L - Pull selected
- [ ] F - Fetch/refresh
- [ ] m - Mount toggle
- [ ] M - Mount menu

### 6.6 Panel Shortcuts
- [ ] J - Jobs panel
- [ ] C - Config menu
- [ ] ? - Help screen
- [ ] q - Quit

### 6.7 Visual Feedback
- [ ] Color coding (green/yellow/red/cyan)
- [ ] Progress bars for active syncs
- [ ] Selection indicator ([x] / [ ])
- [ ] Refresh spinner

### 6.8 Jobs Panel
- [ ] List running jobs with progress
- [ ] List completed jobs with status
- [ ] Cancel job option
- [ ] View log option
- [ ] Clear completed option

### 6.9 Config Menu
- [ ] Git config section
- [ ] Rclone config section
- [ ] Global settings
- [ ] Edit repos/rules

**Task 6 Status**: ⏳ Pending

---

## Task 7: CLI Implementation

### 7.1 Command Parser
- [ ] Set up argparse with subparsers
- [ ] No command → launch TUI
- [ ] Handle --help for all commands

### 7.2 Git Commands
- [ ] `git status` - Show Git repos status
- [ ] `git sync [repo]` - Sync repos
- [ ] `git push [repo]` - Push repos
- [ ] `git pull [repo]` - Pull repos
- [ ] `git fetch` - Fetch all

### 7.3 Rclone Commands
- [ ] `rclone status` - Show rules status
- [ ] `rclone sync [rule]` - Run sync rules
- [ ] `rclone mount` - Mount default remote
- [ ] `rclone umount` - Unmount

### 7.4 Unified Commands
- [ ] `status` - All status
- [ ] `sync --all` - Sync everything
- [ ] `jobs` - List jobs

### 7.5 Server Command
- [ ] `serve` - Start API server
- [ ] `serve --port N` - Custom port

**Task 7 Status**: ⏳ Pending

---

## Task 8: Flask API

### 8.1 Setup
- [ ] Create Flask app
- [ ] Enable CORS
- [ ] Error handling

### 8.2 Status Endpoints
- [ ] `GET /api/status` - All status
- [ ] `GET /api/status/git` - Git status
- [ ] `GET /api/status/rclone` - Rclone status
- [ ] `GET /api/status/mounts` - Mount status

### 8.3 Git Endpoints
- [ ] `GET /api/git/repos` - List repos
- [ ] `POST /api/git/sync` - Sync repos
- [ ] `POST /api/git/push` - Push repos
- [ ] `POST /api/git/pull` - Pull repos

### 8.4 Rclone Endpoints
- [ ] `GET /api/rclone/rules` - List rules
- [ ] `POST /api/rclone/sync` - Run sync
- [ ] `POST /api/rclone/mount` - Mount
- [ ] `POST /api/rclone/umount` - Unmount

### 8.5 Job Endpoints
- [ ] `GET /api/jobs` - List jobs
- [ ] `GET /api/jobs/<id>` - Job details
- [ ] `POST /api/jobs/<id>/cancel` - Cancel
- [ ] `DELETE /api/jobs/completed` - Clear

**Task 8 Status**: ⏳ Pending

---

## Testing

### Unit Tests
- [ ] Config manager tests
- [ ] Git manager tests
- [ ] Rclone manager tests
- [ ] Job manager tests

### Integration Tests
- [ ] TUI launches correctly
- [ ] Status shows for all repos
- [ ] Sync operations work
- [ ] Background jobs complete

### Manual Tests
- [ ] `./sync-app.py` - TUI works
- [ ] `./sync-app.py status` - Shows status
- [ ] `./sync-app.py git sync` - Syncs Git
- [ ] `./sync-app.py rclone mount` - Mounts
- [ ] `./sync-app.py serve` - API starts
- [ ] All keyboard shortcuts work
- [ ] Jobs panel shows progress

---

## Notes / Issues

| Date | Issue | Resolution |
|------|-------|------------|
| | | |

---

## Sign-off

| Role | Name | Date | Signature |
|------|------|------|-----------|
| Developer | Sonnet | | ⬜ Pending |
| Architect | Opus | | ⬜ Pending |
| CEO | Diego | | ⬜ Pending |

---

## Time Tracking

| Task | Estimated | Actual | Status |
|------|-----------|--------|--------|
| Task 1: Setup | 30 min | - | ⏳ |
| Task 2: Config | 45 min | - | ⏳ |
| Task 3: Git Manager | 90 min | - | ⏳ |
| Task 4: Rclone Manager | 90 min | - | ⏳ |
| Task 5: Job Manager | 60 min | - | ⏳ |
| Task 6: TUI | 120 min | - | ⏳ |
| Task 7: CLI | 45 min | - | ⏳ |
| Task 8: API | 60 min | - | ⏳ |
| Testing | 60 min | - | ⏳ |
| **TOTAL** | **~10 hours** | **-** | **⏳** |

---

**Last Updated**: 2025-12-04
**Next Step**: Start Task 1 - Project Setup
