# Tasks for Sonnet: Architecture v2 Implementation

**Date**: 2025-12-04
**Assignee**: Sonnet
**Supervisor**: Opus (Architect)
**Approver**: Diego (CEO)

---

## Overview

Implement the new cloud architecture with:
1. Dashboard navigation restructure
2. Backend API updates for new VM topology
3. Wake-on-demand system integration
4. Cost tab split (AI vs Infra)

**Reference Documents:**
- `ARCHITECTURE_V2_20251204.md` - Target architecture
- `MIGRATION_PLAN_V2_20251204.md` - Migration steps
- `TASK_20251204_NAV_RESTRUCTURE.md` - UI/Navigation changes

---

## Task 1: Update cloud_dash.json

**Priority**: HIGH
**Complexity**: Medium
**Files**: `/back-System/cloud/0.spec/cloud_dash.json`

### 1.1 Update VM Definitions

Update `virtualMachines` section to reflect new architecture:

```json
{
  "virtualMachines": {
    "gcloud-arch-1": {
      "id": "gcloud-arch-1",
      "name": "GCloud Arch 1",
      "provider": "gcloud",
      "role": "proxy",
      "category": "services",
      "instanceType": "e2-micro",
      "specs": {
        "cpu": "0.25-2 vCPU (shared)",
        "ram": "1 GB",
        "storage": "30 GB"
      },
      "services": ["npm-gcloud"],
      "status": "active",
      "availability": "24/7",
      "notes": "Central NPM reverse proxy"
    },
    "oracle-web-server-1": {
      "services": ["mail-app", "mail-db"],
      "notes": "Mail services only",
      "status": "active",
      "availability": "24/7"
    },
    "oracle-services-server-1": {
      "services": ["analytics-app", "analytics-db"],
      "notes": "Matomo Analytics only (no NPM)",
      "status": "active",
      "availability": "24/7"
    },
    "oracle-dev-server": {
      "id": "oracle-dev-server",
      "name": "Oracle Dev Server",
      "provider": "oracle",
      "role": "development",
      "category": "services",
      "instanceType": "VM.Standard.E4.Flex",
      "specs": {
        "cpu": "1 OCPU (2 vCPU)",
        "ram": "8 GB",
        "storage": "100 GB"
      },
      "services": ["n8n-infra-app", "sync-app", "git-app", "cloud-app", "cloud-api", "terminal-app", "vpn-app", "cache-app"],
      "status": "active",
      "availability": "wake-on-demand",
      "wakeConfig": {
        "idleTimeout": 1800,
        "wakeTime": 60,
        "triggerUrl": "https://wake.diegonmarcos.com/dev"
      },
      "cost": {
        "hourly": 0.037,
        "estimatedMonthly": 5.50
      },
      "notes": "Dormant VM - wakes on HTTP request"
    }
  }
}
```

### 1.2 Update Service Mappings

Move services to correct VMs in `services` section:

| Service | Old VM | New VM |
|---------|--------|--------|
| npm-oracle-web | oracle-web-server-1 | REMOVED |
| npm-oracle-services | oracle-services-server-1 | REMOVED |
| npm-gcloud | gcloud-arch-1 | gcloud-arch-1 (primary) |
| n8n-infra-app | oracle-web-server-1 | oracle-dev-server |
| sync-app | oracle-web-server-1 | oracle-dev-server |
| git-app | oracle-web-server-1 | oracle-dev-server |
| cloud-api | oracle-web-server-1 | oracle-dev-server |
| mail-app | gcloud-arch-1 | oracle-web-server-1 |

### 1.3 Add Wake-on-Demand Configuration

Add new section to JSON:

```json
{
  "wakeOnDemand": {
    "enabled": true,
    "targetVm": "oracle-dev-server",
    "functionEndpoint": "https://functions.eu-marseille-1.oraclecloud.com/wake-vm",
    "healthCheckUrl": "https://n8n.diegonmarcos.com/healthz",
    "idleTimeoutSeconds": 1800,
    "wakeTimeSeconds": 60,
    "services": ["n8n", "sync", "git", "cloud", "terminal"]
  }
}
```

### 1.4 Update Resources Totals

Recalculate RAM/Storage totals based on new VM allocation.

---

## Task 2: Dashboard Navigation Restructure

**Priority**: HIGH
**Complexity**: High
**Files**:
- `/front-Github_io/cloud/src_vanilla/index.html`
- `/front-Github_io/cloud/src_vanilla/cloud_dash.html`

### 2.1 Remove Backlog

Delete from navigation in both files:
- Remove "Backlog" button
- Remove backlog-related HTML content
- Remove backlog CSS styles
- Remove backlog JavaScript

### 2.2 Restructure Services Navigation

**Target structure:**
```
Services
├── Front (tab)
│   └── [Cards | List] toggle
└── Back (tab)
    └── [Cards | List] toggle
```

**HTML for index.html:**
```html
<div class="view-group">
    <span class="view-group-label">Services</span>
    <div class="view-group-buttons">
        <button class="view-btn active" data-view="front">Front</button>
        <button class="view-btn" data-view="back">Back</button>
    </div>
    <div class="view-mode-toggle">
        <button class="mode-btn active" data-mode="cards" title="Cards View">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <rect x="3" y="3" width="7" height="7"/>
                <rect x="14" y="3" width="7" height="7"/>
                <rect x="3" y="14" width="7" height="7"/>
                <rect x="14" y="14" width="7" height="7"/>
            </svg>
        </button>
        <button class="mode-btn" data-mode="list" title="List View">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/>
            </svg>
        </button>
    </div>
</div>
```

### 2.3 Update Monitoring Navigation

**Target structure:**
```
Monitoring
├── Status → cloud_dash.html#status
├── Performance → cloud_dash.html#performance
└── Cost → cloud_dash.html#cost
```

Update links to point to cloud_dash.html with hash anchors.

### 2.4 Add Status Tab View Toggle

Inside Status tab in cloud_dash.html, add Tree/List toggle:

```html
<div id="status-tab" class="tab-content active">
    <div class="status-view-toggle">
        <button class="status-mode-btn active" data-status-mode="list">
            <svg><!-- list icon --></svg> List
        </button>
        <button class="status-mode-btn" data-status-mode="tree">
            <svg><!-- tree icon --></svg> Tree
        </button>
    </div>

    <div id="status-list-view" class="status-view active">
        <!-- Current list content -->
    </div>

    <div id="status-tree-view" class="status-view">
        <!-- Tree view content (can be placeholder initially) -->
    </div>
</div>
```

---

## Task 3: Cost Tab Split (AI vs Infra)

**Priority**: HIGH
**Complexity**: Medium
**Files**: `/front-Github_io/cloud/src_vanilla/cloud_dash.html`

### 3.1 Add Sub-tab Navigation

```html
<div id="cost-tab" class="tab-content">
    <div class="cost-subtabs">
        <button class="cost-subtab active" data-cost-tab="ai">
            <svg><!-- AI icon --></svg> AI Costs
        </button>
        <button class="cost-subtab" data-cost-tab="infra">
            <svg><!-- server icon --></svg> Infrastructure
        </button>
    </div>

    <div id="cost-ai-content" class="cost-content active">
        <!-- AI cost content (ccusage data) -->
    </div>

    <div id="cost-infra-content" class="cost-content">
        <!-- Infrastructure cost content -->
    </div>
</div>
```

### 3.2 AI Sub-tab Content

Move existing cost content here:
- Summary cards (Today | Session | Monthly)
- 5h block details
- Model distribution bar
- Monthly/Daily tables

### 3.3 Infra Sub-tab Content

Create new content:
```html
<div id="cost-infra-content" class="cost-content">
    <!-- Summary Cards -->
    <div class="cost-summary-grid">
        <div class="cost-card">
            <div class="cost-card-label">Total Monthly</div>
            <div class="cost-card-value">$8</div>
            <div class="cost-card-detail">~$5-7 dormant VM</div>
        </div>
        <div class="cost-card">
            <div class="cost-card-label">Free Tier</div>
            <div class="cost-card-value">3 VMs</div>
            <div class="cost-card-detail">Oracle + GCloud</div>
        </div>
        <div class="cost-card">
            <div class="cost-card-label">Paid</div>
            <div class="cost-card-value">1 VM</div>
            <div class="cost-card-detail">Wake-on-demand</div>
        </div>
    </div>

    <!-- Provider Breakdown Table -->
    <div class="resources-section">
        <h4 class="resources-section-title">Provider Costs</h4>
        <table class="resources-table">
            <thead>
                <tr>
                    <th>Provider</th>
                    <th>Tier</th>
                    <th>VMs</th>
                    <th>Monthly</th>
                    <th>Status</th>
                </tr>
            </thead>
            <tbody>
                <tr>
                    <td>Oracle Cloud</td>
                    <td>Always Free</td>
                    <td>2</td>
                    <td>$0</td>
                    <td><span class="status-badge on">Active</span></td>
                </tr>
                <tr>
                    <td>Oracle Cloud</td>
                    <td>Paid (E4.Flex)</td>
                    <td>1</td>
                    <td>~$5-7</td>
                    <td><span class="status-badge on">Dormant</span></td>
                </tr>
                <tr>
                    <td>Google Cloud</td>
                    <td>Free Tier</td>
                    <td>1</td>
                    <td>$0</td>
                    <td><span class="status-badge on">Active</span></td>
                </tr>
                <tr class="totals-row">
                    <td><strong>Total</strong></td>
                    <td>-</td>
                    <td>4</td>
                    <td><strong>~$5-7</strong></td>
                    <td>-</td>
                </tr>
            </tbody>
        </table>
    </div>

    <!-- VM Cost Details -->
    <div class="resources-section">
        <h4 class="resources-section-title">VM Details</h4>
        <table class="resources-table">
            <thead>
                <tr>
                    <th>VM</th>
                    <th>Role</th>
                    <th>RAM</th>
                    <th>Availability</th>
                    <th>Est. Hours</th>
                    <th>Monthly</th>
                </tr>
            </thead>
            <tbody>
                <tr>
                    <td>GCloud Arch 1</td>
                    <td>NPM Proxy</td>
                    <td>1 GB</td>
                    <td>24/7</td>
                    <td>730h</td>
                    <td>$0</td>
                </tr>
                <tr>
                    <td>Oracle Web 1</td>
                    <td>Mail</td>
                    <td>1 GB</td>
                    <td>24/7</td>
                    <td>730h</td>
                    <td>$0</td>
                </tr>
                <tr>
                    <td>Oracle Services 1</td>
                    <td>Analytics</td>
                    <td>1 GB</td>
                    <td>24/7</td>
                    <td>730h</td>
                    <td>$0</td>
                </tr>
                <tr>
                    <td>Oracle Dev Server</td>
                    <td>Dev Services</td>
                    <td>8 GB</td>
                    <td>On-Demand</td>
                    <td>~150h</td>
                    <td>~$5-7</td>
                </tr>
            </tbody>
        </table>
    </div>
</div>
```

### 3.4 Add Sub-tab JavaScript

```javascript
function initCostSubtabs() {
    const subtabs = document.querySelectorAll('.cost-subtab');
    const contents = document.querySelectorAll('.cost-content');

    subtabs.forEach(btn => {
        btn.addEventListener('click', () => {
            const target = btn.dataset.costTab;

            subtabs.forEach(b => b.classList.remove('active'));
            contents.forEach(c => c.classList.remove('active'));

            btn.classList.add('active');
            document.getElementById(`cost-${target}-content`).classList.add('active');
        });
    });
}
```

### 3.5 Add Sub-tab CSS

```css
.cost-subtabs {
    display: flex;
    gap: 0.5rem;
    margin-bottom: 1.5rem;
    padding: 0.25rem;
    background: var(--bg-secondary);
    border-radius: var(--border-radius);
    border: 1px solid var(--border-color);
}

.cost-subtab {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 0.5rem;
    padding: 0.6rem 1rem;
    background: transparent;
    border: none;
    border-radius: var(--border-radius);
    color: var(--text-secondary);
    font-family: var(--font-mono);
    font-size: 0.8rem;
    cursor: pointer;
    transition: all var(--transition-speed) ease;
}

.cost-subtab:hover {
    color: var(--text-primary);
    background: var(--bg-card);
}

.cost-subtab.active {
    background: var(--accent-primary);
    color: #000;
}

.cost-subtab svg {
    width: 16px;
    height: 16px;
}

.cost-content {
    display: none;
}

.cost-content.active {
    display: block;
    animation: fadeIn 0.3s ease-out;
}

[data-theme=blurred] .cost-subtabs {
    background: rgba(255, 255, 255, 0.03);
    border-radius: 16px;
}

[data-theme=blurred] .cost-subtab {
    border-radius: 12px;
}

[data-theme=blurred] .cost-subtab.active {
    background: linear-gradient(135deg, var(--accent-blue), var(--accent-purple));
    color: #fff;
}
```

---

## Task 4: Backend API Updates

**Priority**: Medium
**Complexity**: Medium
**Files**: `/back-System/cloud/0.spec/cloud_dash.py`

### 4.1 Update VM Endpoints

Update `/api/metrics/vms` to reflect new VM topology:
- Add `oracle-dev-server`
- Update service mappings
- Add wake status indicator

### 4.2 Add Wake-on-Demand Endpoints

```python
@app.route('/api/wake/status')
def wake_status():
    """Check if dormant VM is running."""
    # Check OCI API for instance state
    pass

@app.route('/api/wake/trigger', methods=['POST'])
def wake_trigger():
    """Trigger VM wake via OCI Function."""
    # Call OCI Function endpoint
    pass
```

### 4.3 Add Infra Cost Endpoint

```python
@app.route('/api/costs/infra')
def get_infra_costs():
    """Return infrastructure costs from config."""
    return jsonify({
        "providers": [
            {"name": "Oracle Cloud", "tier": "Always Free", "vms": 2, "monthly": 0},
            {"name": "Oracle Cloud", "tier": "Paid", "vms": 1, "monthly": 5.50},
            {"name": "Google Cloud", "tier": "Free Tier", "vms": 1, "monthly": 0}
        ],
        "total": 5.50,
        "estimatedRange": {"min": 5, "max": 8}
    })
```

---

## Task 5: Status Tab - VM Status Display

**Priority**: Medium
**Complexity**: Low
**Files**: `/front-Github_io/cloud/src_vanilla/cloud_dash.html`

### 5.1 Update VMs Table

Update the VMs section to show new architecture:

| Mode | VM | Role | IP | RAM | Availability | Status |
|------|-----|------|-----|-----|--------------|--------|
| ON | GCloud Arch 1 | NPM Proxy | x.x.x.x | 1GB | 24/7 | Online |
| ON | Oracle Web 1 | Mail | 130.110.251.193 | 1GB | 24/7 | Online |
| ON | Oracle Services 1 | Analytics | 129.151.228.66 | 1GB | 24/7 | Online |
| ON | Oracle Dev Server | Dev Services | x.x.x.x | 8GB | On-Demand | Sleeping/Running |

### 5.2 Add Wake Button for Dormant VM

```html
<tr class="vm-row" data-vm="oracle-dev-server">
    <td><span class="status-badge on">ON</span></td>
    <td><strong>Oracle Dev Server</strong></td>
    <td>Dev Services</td>
    <td id="dev-server-ip">--</td>
    <td>8 GB</td>
    <td>On-Demand</td>
    <td>
        <span class="live-status" id="dev-server-status">
            <span class="live-dot"></span>
            <span id="dev-server-status-text">Checking...</span>
        </span>
    </td>
    <td>
        <button class="wake-btn" id="wake-dev-btn" onclick="wakeDevServer()">
            <svg><!-- power icon --></svg> Wake
        </button>
    </td>
</tr>
```

### 5.3 Add Wake Button JavaScript

```javascript
async function checkDevServerStatus() {
    try {
        const resp = await fetch('/api/wake/status');
        const data = await resp.json();

        const statusEl = document.getElementById('dev-server-status');
        const textEl = document.getElementById('dev-server-status-text');
        const wakeBtn = document.getElementById('wake-dev-btn');

        if (data.state === 'RUNNING') {
            statusEl.className = 'live-status online';
            textEl.textContent = 'Running';
            wakeBtn.disabled = true;
            wakeBtn.textContent = 'Running';
        } else if (data.state === 'STOPPED') {
            statusEl.className = 'live-status offline';
            textEl.textContent = 'Sleeping';
            wakeBtn.disabled = false;
        } else {
            statusEl.className = 'live-status checking';
            textEl.textContent = data.state;
        }
    } catch (e) {
        console.error('Failed to check dev server status:', e);
    }
}

async function wakeDevServer() {
    const wakeBtn = document.getElementById('wake-dev-btn');
    wakeBtn.disabled = true;
    wakeBtn.innerHTML = '<span class="spinner"></span> Waking...';

    try {
        await fetch('/api/wake/trigger', { method: 'POST' });

        // Poll for running status
        const checkInterval = setInterval(async () => {
            const resp = await fetch('/api/wake/status');
            const data = await resp.json();

            if (data.state === 'RUNNING') {
                clearInterval(checkInterval);
                checkDevServerStatus();
            }
        }, 5000);

        // Timeout after 2 minutes
        setTimeout(() => clearInterval(checkInterval), 120000);
    } catch (e) {
        console.error('Failed to wake dev server:', e);
        wakeBtn.disabled = false;
        wakeBtn.textContent = 'Wake';
    }
}

// Check status on page load
document.addEventListener('DOMContentLoaded', checkDevServerStatus);
```

---

## Task 6: CSS Styling Updates

**Priority**: Low
**Complexity**: Low
**Files**: `/front-Github_io/cloud/src_vanilla/cloud_dash.html`

### 6.1 Wake Button Styles

```css
.wake-btn {
    display: inline-flex;
    align-items: center;
    gap: 0.3rem;
    padding: 0.3rem 0.6rem;
    background: var(--bg-secondary);
    border: 1px solid var(--accent-green);
    border-radius: var(--border-radius);
    color: var(--accent-green);
    font-size: 0.7rem;
    font-weight: 600;
    cursor: pointer;
    transition: all 0.2s ease;
}

.wake-btn:hover:not(:disabled) {
    background: var(--accent-green);
    color: #000;
}

.wake-btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
    border-color: var(--border-color);
    color: var(--text-secondary);
}

.wake-btn svg {
    width: 12px;
    height: 12px;
}

.wake-btn .spinner {
    width: 12px;
    height: 12px;
    border: 2px solid transparent;
    border-top-color: currentColor;
    border-radius: 50%;
    animation: spin 1s linear infinite;
}

[data-theme=blurred] .wake-btn {
    border-radius: 8px;
    background: rgba(16, 185, 129, 0.1);
}

[data-theme=blurred] .wake-btn:hover:not(:disabled) {
    background: var(--accent-green);
    box-shadow: 0 0 15px rgba(16, 185, 129, 0.3);
}
```

### 6.2 View Mode Toggle Styles

```css
.view-mode-toggle {
    display: flex;
    gap: 0.25rem;
    margin-left: 0.5rem;
    padding: 0.2rem;
    background: var(--bg-secondary);
    border: 1px solid var(--border-color);
    border-radius: var(--border-radius);
}

.mode-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 28px;
    padding: 0;
    background: transparent;
    border: none;
    border-radius: var(--border-radius);
    color: var(--text-secondary);
    cursor: pointer;
    transition: all 0.2s ease;
}

.mode-btn svg {
    width: 14px;
    height: 14px;
}

.mode-btn:hover {
    color: var(--accent-primary);
    background: var(--bg-card);
}

.mode-btn.active {
    color: var(--accent-primary);
    background: var(--bg-card);
}

[data-theme=blurred] .view-mode-toggle {
    background: rgba(255, 255, 255, 0.03);
    border-radius: 8px;
}

[data-theme=blurred] .mode-btn {
    border-radius: 6px;
}

[data-theme=blurred] .mode-btn.active {
    background: rgba(74, 158, 255, 0.2);
    color: var(--accent-blue);
}
```

---

## Deliverables Checklist

### Files to Modify
- [ ] `/back-System/cloud/0.spec/cloud_dash.json`
- [ ] `/back-System/cloud/0.spec/cloud_dash.py`
- [ ] `/front-Github_io/cloud/src_vanilla/index.html`
- [ ] `/front-Github_io/cloud/src_vanilla/cloud_dash.html`

### Features to Implement
- [ ] JSON updated with new VM topology
- [ ] Backlog removed from navigation
- [ ] Services nav: Front/Back tabs + Cards/List toggle
- [ ] Monitoring nav: Status/Performance/Cost links
- [ ] Status tab: Tree/List toggle
- [ ] Cost tab: AI/Infra sub-tabs
- [ ] Wake-on-demand button and status
- [ ] All CSS for both themes

### Testing
- [ ] Build succeeds (`./1.ops/build.sh build --vanilla`)
- [ ] All tabs work in minimalistic theme
- [ ] All tabs work in blurred theme
- [ ] Mobile responsive
- [ ] No console errors

---

## Commit Message Template

```
feat(cloud): implement architecture v2 with wake-on-demand

Architecture:
- Single NPM on GCloud (central proxy)
- Mail on Oracle Web 1
- Matomo on Oracle Services 1
- Dev services on Oracle Paid VM (dormant)

Dashboard:
- Remove Backlog from navigation
- Services: Front/Back tabs with Cards/List toggle
- Cost tab: Split into AI and Infra sub-tabs
- Status tab: Add Tree/List toggle
- Add wake button for dormant VM

Backend:
- Update cloud_dash.json with new VM topology
- Add wake-on-demand API endpoints
- Add infra costs endpoint

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
```
