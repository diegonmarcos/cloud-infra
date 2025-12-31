# Architecture v2 Implementation Checklist

**Task**: Cloud Infrastructure Architecture v2 Implementation
**Started**: 2025-12-04
**Assignee**: Sonnet
**Supervisor**: Opus
**Status**: 🚧 IN PROGRESS

---

## Quick Status

| Phase | Status | Progress |
|-------|--------|----------|
| Task 1: Update JSON | ⏳ Pending | 0% |
| Task 2: Nav Restructure | ⏳ Pending | 0% |
| Task 3: Cost Tab Split | ⏳ Pending | 0% |
| Task 4: Backend API | ⏳ Pending | 0% |
| Task 5: Status Tab VM Display | ⏳ Pending | 0% |
| Task 6: CSS Styling | ⏳ Pending | 0% |
| Build & Test | ⏳ Pending | 0% |
| **OVERALL** | **⏳ Pending** | **0%** |

---

## Task 1: Update cloud_dash.json

### 1.1 VM Definitions
- [ ] Add `gcloud-arch-1` VM definition
- [ ] Add `oracle-dev-server` VM definition (8GB, dormant)
- [ ] Update `oracle-web-server-1` services (mail only)
- [ ] Update `oracle-services-server-1` services (matomo only, no NPM)
- [ ] Remove old NPM entries from Oracle VMs

### 1.2 Service Mappings
- [ ] Move `n8n-infra-app` → `oracle-dev-server`
- [ ] Move `sync-app` → `oracle-dev-server`
- [ ] Move `git-app` → `oracle-dev-server`
- [ ] Move `cloud-api` → `oracle-dev-server`
- [ ] Move `mail-app` → `oracle-web-server-1`
- [ ] Update `npm-gcloud` as primary NPM

### 1.3 Wake-on-Demand Config
- [ ] Add `wakeOnDemand` section to JSON
- [ ] Configure target VM, endpoints, timeouts

### 1.4 Resources Totals
- [ ] Recalculate RAM totals per VM
- [ ] Recalculate storage totals
- [ ] Update cost estimates

**Task 1 Status**: ⏳ Pending

---

## Task 2: Navigation Restructure

### 2.1 Remove Backlog
- [ ] Remove Backlog button from `index.html`
- [ ] Remove Backlog button from `cloud_dash.html`
- [ ] Remove Backlog HTML content
- [ ] Remove Backlog CSS styles
- [ ] Remove Backlog JavaScript

### 2.2 Services Navigation (index.html)
- [ ] Replace 4 inline buttons with Front/Back tabs
- [ ] Add Cards/List toggle component
- [ ] Implement view switching JavaScript
- [ ] Test Front + Cards view
- [ ] Test Front + List view
- [ ] Test Back + Cards view
- [ ] Test Back + List view

### 2.3 Monitoring Navigation
- [ ] Update index.html Monitoring links
- [ ] Point to cloud_dash.html#status
- [ ] Point to cloud_dash.html#performance
- [ ] Point to cloud_dash.html#cost
- [ ] Update cloud_dash.html nav to match

### 2.4 Status Tab View Toggle
- [ ] Add Tree/List toggle inside Status tab
- [ ] Create status-list-view container
- [ ] Create status-tree-view container (placeholder OK)
- [ ] Implement toggle JavaScript
- [ ] Move current content to list view

**Task 2 Status**: ⏳ Pending

---

## Task 3: Cost Tab Split

### 3.1 Sub-tab Structure
- [ ] Add cost-subtabs container
- [ ] Add AI sub-tab button
- [ ] Add Infra sub-tab button
- [ ] Create cost-ai-content container
- [ ] Create cost-infra-content container

### 3.2 AI Sub-tab Content
- [ ] Move summary cards (Today/Session/Monthly)
- [ ] Move 5h block details
- [ ] Move model distribution bar
- [ ] Move monthly summary table
- [ ] Move daily breakdown table

### 3.3 Infra Sub-tab Content
- [ ] Add infra summary cards (Total/Free/Paid)
- [ ] Add provider costs table
- [ ] Add VM details table
- [ ] Show dormant VM cost estimate

### 3.4 Sub-tab JavaScript
- [ ] Implement `initCostSubtabs()` function
- [ ] Handle tab switching
- [ ] Default to AI tab

### 3.5 Sub-tab CSS
- [ ] Style cost-subtabs container
- [ ] Style cost-subtab buttons
- [ ] Style active state
- [ ] Style for minimalistic theme
- [ ] Style for blurred theme

**Task 3 Status**: ⏳ Pending

---

## Task 4: Backend API Updates

### 4.1 VM Endpoints
- [ ] Update `/api/metrics/vms` with new topology
- [ ] Add oracle-dev-server to response
- [ ] Add wake status to dormant VM

### 4.2 Wake-on-Demand Endpoints
- [ ] Implement `/api/wake/status` endpoint
- [ ] Implement `/api/wake/trigger` endpoint
- [ ] Add OCI API integration (or placeholder)

### 4.3 Infra Cost Endpoint
- [ ] Implement `/api/costs/infra` endpoint
- [ ] Return provider breakdown
- [ ] Return VM cost details

**Task 4 Status**: ⏳ Pending

---

## Task 5: Status Tab VM Display

### 5.1 Update VMs Table
- [ ] Add GCloud Arch 1 row
- [ ] Update Oracle Web 1 role (Mail)
- [ ] Update Oracle Services 1 role (Analytics)
- [ ] Add Oracle Dev Server row (dormant)
- [ ] Add Availability column

### 5.2 Wake Button
- [ ] Add Wake button to dormant VM row
- [ ] Implement `checkDevServerStatus()` function
- [ ] Implement `wakeDevServer()` function
- [ ] Show spinner while waking
- [ ] Poll for running status

### 5.3 Status Indicators
- [ ] Show "Running" when VM is up
- [ ] Show "Sleeping" when VM is stopped
- [ ] Show "Waking..." during startup
- [ ] Disable Wake button when running

**Task 5 Status**: ⏳ Pending

---

## Task 6: CSS Styling

### 6.1 Wake Button Styles
- [ ] Base wake-btn styles
- [ ] Hover state
- [ ] Disabled state
- [ ] Spinner animation
- [ ] Minimalistic theme
- [ ] Blurred theme

### 6.2 View Mode Toggle Styles
- [ ] view-mode-toggle container
- [ ] mode-btn styles
- [ ] Active state
- [ ] Minimalistic theme
- [ ] Blurred theme

### 6.3 Status View Toggle Styles
- [ ] status-view-toggle container
- [ ] status-mode-btn styles
- [ ] Active state
- [ ] Both themes

**Task 6 Status**: ⏳ Pending

---

## Build & Test

### Build
- [ ] Run `./1.ops/build.sh build --vanilla`
- [ ] Build completes without errors
- [ ] Check dist_vanilla/ files generated

### Functional Testing
- [ ] Backlog completely removed
- [ ] Services Front tab works
- [ ] Services Back tab works
- [ ] Cards/List toggle works
- [ ] Monitoring → Status link works
- [ ] Monitoring → Performance link works
- [ ] Monitoring → Cost link works
- [ ] Status tab Tree/List toggle works
- [ ] Cost → AI sub-tab works
- [ ] Cost → Infra sub-tab works
- [ ] Wake button displays correct state

### Theme Testing
- [ ] Minimalistic theme - all features work
- [ ] Blurred theme - all features work
- [ ] Color consistency across tabs

### Responsive Testing
- [ ] Desktop layout correct
- [ ] Tablet layout correct
- [ ] Mobile layout correct

### Console Check
- [ ] No JavaScript errors
- [ ] No CSS warnings
- [ ] No 404 errors

**Build & Test Status**: ⏳ Pending

---

## Git Workflow

- [ ] All files saved
- [ ] Run final build
- [ ] Stage changes: `git add .`
- [ ] Create commit with template message
- [ ] Push to remote

---

## Notes / Issues

_Track any blockers, decisions, or discoveries here_

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
| Task 1: JSON Update | 30 min | - | ⏳ |
| Task 2: Nav Restructure | 60 min | - | ⏳ |
| Task 3: Cost Tab Split | 45 min | - | ⏳ |
| Task 4: Backend API | 30 min | - | ⏳ |
| Task 5: Status VM Display | 30 min | - | ⏳ |
| Task 6: CSS Styling | 30 min | - | ⏳ |
| Build & Test | 30 min | - | ⏳ |
| **TOTAL** | **4h 15min** | **-** | **⏳** |

---

**Last Updated**: 2025-12-04
**Next Step**: Start Task 1 - Update cloud_dash.json
