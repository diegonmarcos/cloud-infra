# Lightweight Monitoring System - Implementation Plan

**Document:** PLAN_Monitoring.md
**Status:** READY FOR IMPLEMENTATION
**Date:** 2025-12-09

---

## Overview

Lightweight monitoring system for 4 VMs without Prometheus/Grafana overhead. Python collectors, JSON data, Flask API, and Vanilla JS dashboard.

---

## 1. Architecture

```
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│ oci-f-micro_1│    │ oci-f-micro_2│    │ gcp-f-micro_1│
│   (Mail)     │    │  (Matomo)    │    │   (NPM)      │
│              │    │              │    │              │
│ collector.py │    │ collector.py │    │ collector.py │
│      │       │    │      │       │    │      │       │
│      ▼       │    │      ▼       │    │      ▼       │
│ metrics.json │    │ metrics.json │    │ metrics.json │
└──────┬───────┘    └──────┬───────┘    └──────┬───────┘
       │                   │                   │
       │    Syncthing     │                   │
       └───────────────────┼───────────────────┘
                           │
                           ▼
              ┌──────────────────────────────┐
              │      oci-p-flex_1 (Dev)       │
              │                              │
              │  /opt/monitoring/data/       │
              │  ├── oci-f-micro_1/         │
              │  ├── oci-f-micro_2/         │
              │  ├── gcp-f-micro_1/         │
              │  └── history/               │
              │                              │
              │  Flask API → cloud_dash.py  │
              │  Alert Checker → cron       │
              │                              │
              └──────────────────────────────┘
                           │
                           ▼
              ┌──────────────────────────────┐
              │   Webfront Dashboard         │
              │  monitoring.html             │
              └──────────────────────────────┘
```

---

## 2. Metrics JSON Schema

**File:** `metrics.json` (per VM)

```json
{
  "vm_id": "oci-f-micro_1",
  "timestamp": "2025-12-09T10:30:00Z",
  "system": {
    "cpu": { "percent": 23.5, "cores": 1 },
    "memory": {
      "total_mb": 1024,
      "used_mb": 756,
      "available_mb": 268,
      "percent": 73.8
    },
    "disk": {
      "total_gb": 47,
      "used_gb": 12,
      "percent": 25.5
    },
    "uptime": { "seconds": 432000, "human": "5 days" },
    "load": { "1m": 0.08, "5m": 0.05, "15m": 0.02 }
  },
  "containers": [
    {
      "name": "mailu-front",
      "status": "running",
      "cpu_percent": 0.5,
      "memory_mb": 45
    }
  ],
  "services": [
    {
      "id": "mail",
      "healthy": true,
      "response_ms": 125
    }
  ]
}
```

---

## 3. Python Collector

**File:** `/opt/monitoring/collector.py`

```python
#!/usr/bin/env python3
"""Lightweight Metrics Collector - runs via cron every 5 minutes."""

import json
import os
import subprocess
from datetime import datetime
from pathlib import Path

VM_ID = os.environ.get('VM_ID', 'unknown')
OUTPUT_DIR = Path('/opt/monitoring/data') / VM_ID

class MetricsCollector:
    def __init__(self):
        self.timestamp = datetime.utcnow().isoformat() + 'Z'

    def collect_all(self):
        return {
            'vm_id': VM_ID,
            'timestamp': self.timestamp,
            'system': self.collect_system(),
            'containers': self.collect_containers(),
            'services': self.collect_services()
        }

    def collect_system(self):
        # CPU from /proc/stat
        # Memory from free -m
        # Disk from df -h /
        return {...}

    def collect_containers(self):
        # docker stats --no-stream --format json
        return [...]

    def collect_services(self):
        # HTTP health checks
        return [...]

def main():
    collector = MetricsCollector()
    metrics = collector.collect_all()

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    with open(OUTPUT_DIR / 'metrics.json', 'w') as f:
        json.dump(metrics, f, indent=2)

if __name__ == "__main__":
    main()
```

---

## 4. Flask API Endpoints

Add to `cloud_dash.py`:

```python
MONITORING_DATA_DIR = Path('/opt/monitoring/data')

@app.route('/api/monitoring/summary')
def api_monitoring_summary():
    """Get current metrics for all VMs."""
    vms = {}
    for vm_dir in MONITORING_DATA_DIR.iterdir():
        if vm_dir.is_dir():
            metrics_file = vm_dir / 'metrics.json'
            if metrics_file.exists():
                with open(metrics_file) as f:
                    vms[vm_dir.name] = json.load(f)
    return jsonify({'vms': vms})

@app.route('/api/monitoring/vm/<vm_id>')
def api_monitoring_vm(vm_id):
    """Get metrics for single VM."""
    metrics_file = MONITORING_DATA_DIR / vm_id / 'metrics.json'
    if not metrics_file.exists():
        return jsonify({'error': 'Not found'}), 404
    with open(metrics_file) as f:
        return jsonify(json.load(f))

@app.route('/api/monitoring/alerts')
def api_monitoring_alerts():
    """Get active alerts."""
    alerts_file = MONITORING_DATA_DIR / 'alerts.json'
    if not alerts_file.exists():
        return jsonify({'alerts': []})
    with open(alerts_file) as f:
        return jsonify(json.load(f))
```

---

## 5. Alert Thresholds

Add to `cloud_dash.json`:

```json
{
  "monitoring": {
    "thresholds": {
      "cpu": { "warning": 70, "critical": 90 },
      "memory": { "warning": 80, "critical": 95 },
      "disk": { "warning": 80, "critical": 90 }
    },
    "notifications": {
      "email": {
        "enabled": true,
        "smtp_host": "smtp.gmail.com",
        "recipients": ["me@diegonmarcos.com"]
      },
      "cooldown_minutes": 30
    }
  }
}
```

---

## 6. Alert Checker

**File:** `/opt/monitoring/alert_checker.py`

```python
#!/usr/bin/env python3
"""Alert Checker - runs via cron every 5 minutes."""

import json
import smtplib
from email.mime.text import MIMEText
from pathlib import Path

ALERTS_FILE = Path('/opt/monitoring/data/alerts.json')

def check_thresholds():
    # Load metrics, compare to thresholds
    # If exceeded, create/update alert
    # Send email if new alert or escalation
    pass

def send_alert_email(alert):
    # Use Gmail SMTP from LOCAL_KEYS
    pass

if __name__ == "__main__":
    check_thresholds()
```

---

## 7. Cron Schedule

**Per VM (`/etc/cron.d/monitoring`):**
```cron
# Collect metrics every 5 minutes
*/5 * * * * root /opt/monitoring/collector.py
```

**Dev VM only:**
```cron
# Check alerts every 5 minutes
*/5 * * * * root /opt/monitoring/alert_checker.py

# Daily aggregation at 23:55
55 23 * * * root /opt/monitoring/aggregator.py
```

---

## 8. Webfront Components

**File:** `monitoring.html`

```html
<div class="dashboard">
  <header>
    <h1>Infrastructure Monitoring</h1>
    <span class="status-dot"></span>
  </header>

  <nav class="view-toggle">
    <button data-view="overview">Overview</button>
    <button data-view="services">Services</button>
    <button data-view="alerts">Alerts</button>
  </nav>

  <section id="overview">
    <div class="vm-grid">
      <!-- VM cards with gauges -->
    </div>
  </section>
</div>

<script>
async function loadMetrics() {
  const res = await fetch('/api/monitoring/summary');
  const data = await res.json();
  renderVmCards(data.vms);
}

function renderGauge(canvas, value, max) {
  const ctx = canvas.getContext('2d');
  // Draw arc gauge
}
</script>
```

---

## 9. Implementation Steps

1. Create `/opt/monitoring/` directory structure on all VMs
2. Write `collector.py` with system metrics collection
3. Configure Syncthing folder sync
4. Add Flask API endpoints to `cloud_dash.py`
5. Write `alert_checker.py` with Gmail SMTP
6. Set up cron jobs
7. Create `monitoring.html` webfront
8. Test end-to-end flow

---

## 10. File Structure

```
/opt/monitoring/
├── collector.py           # All VMs
├── alert_checker.py       # Dev VM only
├── aggregator.py          # Dev VM only
├── data/
│   ├── oci-f-micro_1/metrics.json
│   ├── oci-f-micro_2/metrics.json
│   ├── gcp-f-micro_1/metrics.json
│   ├── oci-p-flex_1/metrics.json
│   ├── alerts.json
│   └── history/
│       └── YYYY-MM-DD.json
```

---

## Critical Files

- `/home/diego/Documents/Git/back-System/cloud/1.ops/cloud_dash.py` - Add API endpoints
- `/home/diego/Documents/Git/back-System/cloud/1.ops/cloud_dash.json` - Add monitoring config
- `/home/diego/Documents/Git/LOCAL_KEYS/README.md` - Gmail SMTP credentials
