# Tester spec — tier-1 protection + graduated shed under real memory pressure

> Covers PLAN-hardening-2026-07-07 §3B (tier-1 app protection) and §3C (graduated
> shedding). This is a **dispatchable GHA job against a disposable scratch VM** —
> it induces real memory thrash with `stress-ng` and asserts the protection stack
> behaves. **NEVER run on termux, on a 1GB production VM, or on the mesh hub.**
> Runtime counterpart to the pure-eval `test-protection-data-driven.sh`.

## Why a separate harness

`test-protection-data-driven.sh` proves the *thresholds/tier-lists are wired
data-driven* (static eval). It cannot prove the *runtime behaviour*: that the
load-shedder actually sheds non-tier-1 first, spares tier-1 until last resort,
fires ntfy, and that tier1-watchdog restarts a killed tier-1 container with a
working circuit breaker. That needs a live box under pressure — hence this job.

## Target

- A throwaway VM (OCI E2 scratch or a GHA-provisioned VM), NOT any of the 4 prod
  VMs. Provision with the same vm-pilot HM image + a fake `tier1_services` list
  pointing at two dummy containers (`t1-a`, `t1-b`) and two sheddable dummies
  (`bulk-a`, `bulk-b`).
- Containers: tiny `busybox sleep infinity` images so the only variable is memory.

## Setup (GHA step, on the scratch VM over SSH)

```bash
# Dummy workload — 2 tier-1 + 2 sheddable, all trivially small.
for n in t1-a t1-b bulk-a bulk-b; do
  docker run -d --name "$n" busybox sleep infinity
done
# tier1_services override for the scratch VM's build.json .protection:
#   ["t1-a","t1-b"]   (bulk-* are intentionally NON-tier-1)
```

## Assertions

| # | Stage | Action | Expected |
|---|-------|--------|----------|
| A | baseline | `docker ps` | all 4 dummies + real tier-1 running; `load-shedder.service` active |
| B | warn (PSI≥warn) | `stress-ng --vm 1 --vm-bytes 55%` | ntfy "Memory pressure WARN" fired; NO container stopped |
| C | crit (PSI≥crit ×N) | `stress-ng --vm 2 --vm-bytes 80%` sustained | `bulk-a`+`bulk-b` STOPPED; `t1-a`+`t1-b` STILL RUNNING; ntfy "non-tier1 stopped" fired; `/run/load-shedder.fired` exists |
| D | page (PSI≥page ×N) | push higher until only tier-1 remain | escalation stops docker (last resort); ntfy priority-5 page fired |
| E | recovery | kill stress-ng; wait `backoff_secs` | shed_level resets; ntfy "RESOLVED" fired |
| F | island survives | throughout B–E | `wg show wg0` handshake fresh; `ssh` + Dropbear `:2200` reachable the entire time (connectivity.slice never starved) |
| G | tier1-watchdog | `docker stop t1-a` (docker still up) | within `tier1_check_interval_secs`, `t1-a` restarted; ntfy "Tier-1 restart" fired |
| H | circuit breaker | make `t1-a` un-startable (bad image), let it fail `tier1_max_restarts`× | watchdog stops retrying; ntfy priority-5 "CIRCUIT OPEN" fired exactly once; no restart storm |
| I | fd guard (P2) | `bash -c 'for i in $(seq 1 N); do exec {fd}<>/tmp/f$i; done'` to push `/proc/sys/fs/file-nr` | health-agent latest.json `fd.status` flips warn→critical at `fd_warn_pct`/`fd_crit_pct`; ntfy fired |
| J | wg-stale (P3) | drop a peer's handshake (block its endpoint) > `wg_stale_secs` | latest.json `wg_peers[].stale=true` for that peer |
| K | deploy-failed (P5) | `touch /run/load-shedder.deploy-failed` | next health-agent tick fires priority-5 "LOAD SHEDDER NOT ARMED" ntfy |

## Verification method

- ntfy: subscribe to the configured `ntfy_topic` (default `health_resources`) via
  `curl -s "$NTFY_BASE/$TOPIC/json?poll=1&since=<start>"` and grep titles.
- container state: `docker inspect -f '{{.State.Running}}' <name>`.
- island: run the whole job over the SSH session and assert it never drops; plus
  `wg show wg0 latest-handshakes`.

## Teardown

Destroy the scratch VM. Never leave stress-ng or dummy containers behind.

## Dispatch

Add as `workflow_dispatch`-only job (`stress-tier1.yml`) gated on an explicit
`i-understand-this-thrashes-a-vm: true` input. Default OFF. Not path-triggered.
