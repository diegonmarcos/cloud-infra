#!/bin/sh
# #840 — a burst of pushes must end with EVERY changed service deployed.
#
# Incident: Ship runs 37136391107 (scrappers-api, #824) and 37136741612 (caddy,
# #655) built their service, then lost "Deploy → <vm>" to a newer entrant on the
# fleet-wide `ship-wg-runner` group (GitHub keeps ONE pending entry per group).
# Both runs concluded `cancelled`; nothing re-queued the deploy until the
# 4-hourly reconcile, so the change sat built-but-not-shipped.
#
# Fix under test: ship-reconcile.yml also triggers on `workflow_run: Ship
# completed`, gated by a job `if:` (loop bound), and a `push`-triggered
# reconcile never re-ships. This tester EXECUTES that logic: it reads the
# triggers, the job `if:`, the re-ship step `if:` and the deploy concurrency
# straight out of the workflows (source AND deployed .github copy), evaluates
# the GHA expressions, and runs them in a discrete-event model of GitHub's
# concurrency semantics (1 running + 1 pending per group, newer pending evicts
# older). The 4-hourly schedule is deliberately NOT modelled: convergence must
# not depend on it.
#
# #844 — the one-pending-slot model above is GitHub's behaviour only while some
# ship-wg-runner entrant lacks `queue: max`. With EVERY entrant declaring it
# (scanned from all workflows below), the group is a FIFO of up to 100 waiting
# entries and nothing is evicted. The "cgc-holder-churn" scenario puts a
# long-running cgc-db restore-all on the lock, a second restore-all waiting,
# a 10-push burst and a stream of workflow_run reconciles behind it: every
# changed service must deploy and no cgc-db restore may be cancelled (#352).
#
# Built-in mutation test: every mutant below must make the model fail. A
# mutant that survives means this tester no longer guards the property.
set -eu
REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
command -v python3 >/dev/null || { echo "::error::needs python3"; exit 1; }
python3 - "$REPO_ROOT" <<'PY'
import copy, re, sys, yaml
root = sys.argv[1]
fails = 0

def load(p):
    y = yaml.safe_load(open(f"{root}/{p}"))
    if True in y and "on" not in y:   # PyYAML reads bare `on:` as True
        y["on"] = y.pop(True)
    return y

def expr(e, ctx):
    """Evaluate the GHA expression subset these `if:`s use."""
    e = re.sub(r"\$\{\{|\}\}", "", str(e))
    def ident(m):
        return repr(ctx.get(m.group(0), ""))
    e = re.sub(r"\b(github|steps|needs)(\.[A-Za-z_][\w-]*)+", ident, e)
    e = re.sub(r"\balways\(\)", "true", e)
    e = e.replace("&&", " and ").replace("||", " or ").replace("!", " not ").replace(" not =", "!=")
    return bool(eval(e, {"true": True, "false": False}, {}))

GROUP = "ship-wg-runner"

def entrants(wfs):
    """Every concurrency block (workflow- or job-level) that names GROUP."""
    out = []
    for path, y in wfs.items():
        blocks = [("<workflow>", y.get("concurrency"))]
        blocks += [(j, (d or {}).get("concurrency")) for j, d in (y.get("jobs") or {}).items()]
        for where, c in blocks:
            if isinstance(c, dict) and c.get("group") == GROUP:
                out.append((path, where, c))
    return out

def fifo_group(wfs):
    """True only when EVERY entrant queues (mixed behaviour is undocumented)."""
    es = entrants(wfs)
    return bool(es) and all(c.get("queue") == "max" and not c.get("cancel-in-progress") for _, _, c in es)

def model(wfs, ship_p, rec_p, scenario):
    ship, rec = wfs[ship_p], wfs[rec_p]
    fifo = fifo_group(wfs) and not scenario.get("legacy")
    ship_name = ship["name"]
    deploy = next(j for j in ship["jobs"].values() if "deploy" in str(j.get("name", "")).lower() and "gate" not in str(j.get("name", "")).lower())
    cc = deploy.get("concurrency") or {}
    group_cancel = bool(cc.get("cancel-in-progress"))
    wr = (rec.get("on") or {}).get("workflow_run") or {}
    on_ship = ship_name in (wr.get("workflows") or []) and "completed" in (wr.get("types") or ["completed"])
    job = rec["jobs"]["reconcile"]
    job_if = job.get("if", "true")
    rq_run = "\n".join(str(x.get("run", "")) for x in (rec["jobs"].get("requeue") or {}).get("steps", []))
    # The requeue step's "newer reconcile already queued?" check. Its jq filter
    # is executed against a fixture below; here we only need whether it exists.
    requeue_skips_if_newer = "NEWER_RECONCILE" in rq_run
    rq = next((j for j in rec["jobs"].values() if j.get("needs") in ("reconcile", ["reconcile"])), None)
    step = next(s for s in job["steps"] if "Re-ship" in str(s.get("name", "")))
    step_if = step.get("if", "true")

    reg = dict(scenario.get("drift", {})); fleet = {k: 0 for k in reg}
    broken = set(scenario.get("broken", []))
    st = {"running": None, "pending": [], "cgc_cancelled": 0, "ver": 0, "evicted": 0, "reconciles": 0, "dispatches": 0, "push_dispatch": 0}
    q = []  # (time, seq, kind, payload)
    seq = [0]
    def at(t, kind, p):
        seq[0] += 1; q.append((t, seq[0], kind, p))

    def finish_ship(run, concl, t):
        if on_ship:
            ctx = {"github.event_name": "workflow_run",
                   "github.event.workflow_run.name": ship_name,
                   "github.event.workflow_run.conclusion": concl,
                   "github.event.workflow_run.event": run["event"]}
            if expr(job_if, ctx):   # workflow_run is delivered AFTER the run ends
                at(t + 0.01, "wr", None)

    def start(t):
        if st["running"] is None and st["pending"]:
            j = st["pending"].pop(0); st["running"] = j
            dur = j.get("dur") or (3 if j["kind"] == "deploy" else 1)
            at(t + dur, "done", j)

    def enqueue(j, t):
        if group_cancel and st["running"] is not None:
            old = st["running"]; st["running"] = None; cancelled(old, t)
        if fifo:
            if len(st["pending"]) >= 100:            # GitHub cancels the newcomer
                st["evicted"] += 1; cancelled(j, t)
            else:
                st["pending"].append(j)
            start(t); return
        old = st["pending"][0] if st["pending"] else None
        st["pending"] = [j]                          # the newcomer exists before the evictee reacts
        if old is not None:
            st["evicted"] += 1; cancelled(old, t)
        start(t)

    def cancelled(j, t):
        if j["kind"] == "cgc":
            st["cgc_cancelled"] += 1
        elif j["kind"] == "deploy":
            finish_ship(j["run"], "cancelled", t)
        elif rq is not None:     # evicted reconcile: the out-of-group requeue job
            ctx = {"needs.reconcile.result": "cancelled", "github.event_name": j["event"]}
            newer = any(x["kind"] == "reconcile" for x in st["pending"]) or any(k in ("wr", "requeue") for _, _, k, _ in q)
            if expr(rq.get("if", "true"), ctx) and not (newer and requeue_skips_if_newer):
                at(t + 0.01, "requeue", None)

    def ship_run(services, event, t):
        run = {"event": event}
        built = {s: reg[s] for s in services}       # build job: always succeeds
        enqueue({"kind": "deploy", "run": run, "built": built}, t)

    for i, svc in enumerate(scenario["pushes"]):
        at(i, "push", svc)
    for t0, dur in scenario.get("cgc", []):
        at(t0, "cgc", dur)
    for t0 in scenario.get("wr_churn", []):
        at(t0, "wr", None)
    if "push_reconcile" in scenario:
        at(scenario["push_reconcile"], "pushrec", None)
    t = 0
    while q:
        q.sort(); t, _, kind, p = q.pop(0)
        if t > 2000: return False, "no quiescence (loop): %s" % st
        if kind == "push":
            st["ver"] += 1; reg[p] = st["ver"]; fleet.setdefault(p, 0)
            ship_run([p], "repository_dispatch", t)
        elif kind == "cgc":
            enqueue({"kind": "cgc", "dur": p}, t)
        elif kind == "wr":
            enqueue({"kind": "reconcile", "event": "workflow_run"}, t)
        elif kind == "requeue":
            enqueue({"kind": "reconcile", "event": "workflow_dispatch"}, t)
        elif kind == "pushrec":
            enqueue({"kind": "reconcile", "event": "push"}, t)
        elif kind == "done":
            st["running"] = None
            if p["kind"] == "cgc":
                pass
            elif p["kind"] == "deploy":
                bad = [s for s in p["built"] if s in broken]
                for s, v in p["built"].items():
                    if s not in broken: fleet[s] = max(fleet[s], v)
                finish_ship(p["run"], "failure" if bad else "success", t)
            else:
                st["reconciles"] += 1
                drift = sorted(s for s in reg if fleet[s] != reg[s])
                ctx = {"github.event_name": p["event"],
                       "steps.reconcile.outputs.rc": "1" if drift else "0",
                       "steps.select.outputs.services": ",".join(drift)}
                if drift and expr(step_if, ctx):
                    st["dispatches"] += 1
                    if p["event"] == "push": st["push_dispatch"] += 1
                    ship_run(drift, "workflow_dispatch", t)
            start(t)
    if st["reconciles"] > 50: return False, "reconcile ran %d times (unbounded chain)" % st["reconciles"]
    if st["cgc_cancelled"]:
        return False, "%d cgc-db restore-all cancelled in the WG queue (#352)" % st["cgc_cancelled"]
    if scenario.get("need_fifo") and not fifo:
        return False, "some %s entrant lacks queue: max — %s" % (GROUP, [(p, w) for p, w, c in entrants(wfs) if c.get("queue") != "max"][:3])
    if st["push_dispatch"]:
        return False, "push-triggered reconcile dispatched Ship (a workflow-file commit deployed services)"
    if scenario.get("need_evictions") and not st["evicted"] and not fifo:
        return False, "scenario never evicted a deploy — it does not exercise #840"
    keep = set(scenario.get("must_stay_drifted", []))
    if any(fleet[s] == reg[s] for s in keep):
        return False, "report-only reconcile deployed %s" % sorted(keep)
    if st["evicted"] > 20 * max(1, len(scenario["pushes"])):
        return False, "eviction thrash: %d evictions for %d pushes" % (st["evicted"], len(scenario["pushes"]))
    lost = sorted(s for s in reg if fleet[s] != reg[s] and s not in broken and s not in keep)
    if lost: return False, "built but never deployed: %s (evictions=%d)" % (lost, st["evicted"])
    return True, "ok (evictions=%d reconciles=%d re-ships=%d)" % (st["evicted"], st["reconciles"], st["dispatches"])

SCEN = {
  "burst":  {"pushes": ["scrappers-api", "caddy", "dagu", "ntfy", "caddy", "mail", "cgc", "scrappers-api", "vault", "ntfy"], "need_evictions": True},
  "broken": {"pushes": ["svc-a", "broken-svc", "svc-b", "svc-c", "broken-svc", "svc-d"], "broken": ["broken-svc"], "need_evictions": True},
  "cgc-holder-churn": {"pushes": ["scrappers-api", "caddy", "dagu", "ntfy", "caddy", "mail", "cgc", "scrappers-api", "vault", "ntfy"],
                       "cgc": [(-1, 240), (4.5, 200)], "wr_churn": [2, 3.5, 6, 8, 9.5], "need_fifo": True},
  "push-reconcile-is-report-only": {"pushes": [], "drift": {"svc-x": 1}, "must_stay_drifted": ["svc-x"], "push_reconcile": 0},
  "evicted-push-reconcile-not-requeued": {"pushes": ["svc-a", "svc-b"], "drift": {"svc-x": 1}, "must_stay_drifted": ["svc-x"], "push_reconcile": 0.5},
}

# The #840/#842 requeue net must still converge if the queue degrades to the
# one-pending-slot behaviour (queue full at 100, or GitHub changes semantics):
# re-run the burst scenarios with FIFO forced off so those mutants stay killed.
for _n in ["burst", "broken", "evicted-push-reconcile-not-requeued"]:
    SCEN["net:" + _n] = dict(SCEN[_n], legacy=True)

def check_all(wfs, sp, rp):
    return [(n,) + model(wfs, sp, rp, s) for n, s in SCEN.items()]

def mut_no_trigger(s, r): r["on"].pop("workflow_run", None)
def mut_wrong_wf(s, r): r["on"]["workflow_run"]["workflows"] = ["Ship → gen-configs (cloud-data)"]
def mut_no_cancelled(s, r):
    j = r["jobs"]["reconcile"]
    j["if"] = "github.event_name != 'workflow_run' || (github.event.workflow_run.conclusion == 'failure' && github.event.workflow_run.event != 'workflow_dispatch')"
def mut_no_loop_bound(s, r): r["jobs"]["reconcile"].pop("if", None)
def mut_no_dispatch_guard(s, r):
    j = r["jobs"]["reconcile"]
    j["if"] = j["if"].replace("github.event.workflow_run.event != 'workflow_dispatch'", "true")
def mut_push_applies(s, r):
    st = next(x for x in r["jobs"]["reconcile"]["steps"] if "Re-ship" in str(x.get("name", "")))
    st["if"] = st["if"].replace("github.event_name != 'push' && ", "")
def mut_no_requeue(s, r): r["jobs"].pop("requeue", None)
def mut_requeue_on_push(s, r):
    r["jobs"]["requeue"]["if"] = r["jobs"]["requeue"]["if"].replace(" && github.event_name != 'push'", "")
def mut_requeue_no_newer_check(s, r):
    for x in r["jobs"]["requeue"]["steps"]: x["run"] = str(x.get("run", "")).replace("NEWER_RECONCILE", "X")
def _noq(c): c.pop("queue", None)
def mut_844_deploy_no_queue(s, r, w):
    _noq(next(j for j in s["jobs"].values() if (j.get("concurrency") or {}).get("group") == GROUP)["concurrency"])
def mut_844_reconcile_no_queue(s, r, w): _noq(r["jobs"]["reconcile"]["concurrency"])
def mut_844_cgc_restore_no_queue(s, r, w):
    _noq(next(y for p, y in w.items() if p.endswith("cgc-db-index.yml"))["jobs"]["restore-all"]["concurrency"])
def mut_844_hm_no_queue(s, r, w):
    _noq(next(y for p, y in w.items() if p.endswith("ship-home-manager.yml"))["concurrency"])
MUT844 = [mut_844_deploy_no_queue, mut_844_reconcile_no_queue, mut_844_cgc_restore_no_queue, mut_844_hm_no_queue]
MUTANTS = [mut_requeue_no_newer_check, mut_no_requeue, mut_requeue_on_push, mut_no_trigger, mut_wrong_wf, mut_no_cancelled, mut_no_loop_bound, mut_no_dispatch_guard, mut_push_applies]

def jq_check(rec):
    """Execute the requeue step's NEWER_RECONCILE jq filter on a fixture."""
    import json, os, subprocess
    st = next(x for x in rec["jobs"]["requeue"]["steps"] if "NEWER_RECONCILE" in (x.get("env") or {}))
    f = st["env"]["NEWER_RECONCILE"]
    fx = {"workflow_runs": [{"id": 90, "status": "queued"}, {"id": 100, "status": "in_progress"},
                            {"id": 120, "status": "completed"}, {"id": 130, "status": "queued"}]}
    def run(me):
        return subprocess.run(["jq", "-r", f], input=json.dumps(fx), capture_output=True, text=True,
                              env=dict(os.environ, ME=str(me))).stdout.strip()
    return [("newer queued run found", run(100), "130"), ("only older/completed -> requeue", run(130), "")]

import glob
for d in ["1_cicd/src/cicd", ".github/workflows"]:
    sp, rp = f"{d}/ship.yml", f"{d}/ship-reconcile.yml"
    print("──", rp)
    wfs = {p[len(root) + 1:]: load(p[len(root) + 1:]) for p in sorted(glob.glob(f"{root}/{d}/*.yml"))}
    ship, rec = wfs[sp], wfs[rp]
    if len(entrants(wfs)) < 9:
        print("  FAIL only %d %s entrants found — scan broken?" % (len(entrants(wfs)), GROUP)); fails += 1
    for name, ok, msg in check_all(wfs, sp, rp):
        print("  %s %s: %s" % ("ok  " if ok else "FAIL", name, msg)); fails += (not ok)
    for name, got, want in jq_check(rec):
        ok = got == want
        print("  %s jq %s (got %r)" % ("ok  " if ok else "FAIL", name, got)); fails += (not ok)
    for m in MUTANTS + MUT844:
        w2 = copy.deepcopy(wfs); s2, r2 = w2[sp], w2[rp]
        m(s2, r2, w2) if m in MUT844 else m(s2, r2)
        bad = [(n, msg) for n, ok, msg in check_all(w2, sp, rp) if not ok]
        if bad: print("  ok   mutant %s killed (%s: %s)" % (m.__name__, bad[0][0], bad[0][1][:90]))
        else:   print("  FAIL mutant %s SURVIVED" % m.__name__); fails += 1
print("FAILED: %d" % fails if fails else "PASS")
sys.exit(1 if fails else 0)
PY
