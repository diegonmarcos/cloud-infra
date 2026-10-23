#!/usr/bin/env bash
# Long jobs must not starve deploys: every job of ship-reconcile and
# ship-home-manager declares timeout-minutes <= 60 (ship-home-manager: <= 90, measured 64-70 min), and cgc-db-index jobs stay
# within 120 minutes (restore-all). Checked on the source AND the deployed copy.
# Usage: bash 9_others/test/test_ship_long_jobs_bounded.sh
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$ROOT" <<'PY'
import sys, yaml
root = sys.argv[1]; fails = 0
budget = {"ship-reconcile.yml": 60, "ship-home-manager.yml": 90, "cgc-db-index.yml": 120}
# ship-home-manager.yml: 90 (not 60) - real activations on the 1 GB VMs measured 64-70 min;
# a 60m cap would kill legitimate deploys (see MEASURED_WORST_MIN in hm-activation-verdict.test.sh).
# cgc-db-index.yml: only restore-all (its WG/deploy-facing job) is capped at 120 (#1061); the
# index matrix holds no concurrency group and keeps its own longer ceiling.
only = {"cgc-db-index.yml": {"restore-all"}}
for base in ("1_cicd/src/cicd", ".github/workflows"):
    for wf, cap in budget.items():
        jobs = yaml.safe_load(open(f"{root}/{base}/{wf}"))["jobs"]
        for name, job in jobs.items():
            if wf in only and name not in only[wf]:
                continue
            t = job.get("timeout-minutes")
            ok = isinstance(t, int) and 0 < t <= cap
            if not ok:
                fails += 1
            print(f"  {'ok  ' if ok else 'FAIL'} {base}/{wf} {name}: timeout-minutes={t} (cap {cap})")
        print(f"  {'ok  ' if jobs else 'FAIL'} {wf} has jobs")
        fails += 0 if jobs else 1
sys.exit(1 if fails else 0)
PY
