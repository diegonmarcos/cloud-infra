# PLAN — Container Engine Verb Restructure ("Kubernetes, efficiently")

**Status:** SPEC — awaiting approval
**Scope decision:** incremental verb layer (no rewrite of the 17 step files) + live GHCR-digest reconcile
**Engine touched:** `1_configs/src/deploy/scripts/cloud-ship-container-engine.sh` (+ new step files)
**Blast radius:** every `a_solutions/*` service (build.sh is a symlink) — verbs appear fleet-wide with zero per-service change.

---

## 1. Mental model — two planes, one reconcile key

Kubernetes is not a command list; it is **desired-vs-observed reconciliation over two source-of-truth planes**.

| Plane | Source of truth (host) | Lands on VM as | k8s analogue |
|-------|------------------------|----------------|--------------|
| **Image** | GHCR image digest | pulled container image | registry + kubelet pull |
| **Config** | `dist/` (compose + `.secrets` + configs) | rsynced `dist/` | `kubectl apply` (Deployment spec) |

**Reconcile key = GHCR digest.** "Is the VM up to date?" = *running container's image digest == pushed GHCR tag digest* AND *VM config hash == `dist/` hash*. That is `kubectl rollout status`.

The engine already enforces the physical model: VMs never build (`step_compose` hardcodes `--no-build --pull always --force-recreate`); `step_docker` builds+pushes to GHCR. This plan makes those movements **addressable as clean verbs** and adds the missing observability.

---

## 2. Verb taxonomy

### Atomic (single responsibility, idempotent)

| Verb | Plane | Action | Backed by |
|------|-------|--------|-----------|
| `build` | local | flake → `dist/` + local image | `step_build` |
| `secrets` | local | sops → `dist/.secrets` | `step_secrets` |
| `push` | image→GHCR | tag + push image (skip build if present) | **split from `step_docker`** |
| `sync` (=`deploy`) | config→VM | rsync `dist/` → VM | `step_deploy` |
| `pull` | GHCR→VM | `docker compose pull` on VM | **extract from `step_compose`** |
| `up` | VM | `compose up -d --no-build` | **extract from `step_compose`** |
| `down` / `restart` | VM | `compose down` / `restart` | new thin wrappers |

### Introspection (read-only — reconcile core)

| Verb | Answers | Status |
|------|---------|--------|
| `status` | per-container: digest InSync/Drift · health · config-hash match | **NEW — `step-status.sh`** |
| `logs` | `compose logs --tail N [-f]` | **NEW — `step-logs.sh`** |
| `diff` | what `ship` would change (dry-run) | optional, phase 2 |

### Composite (data-driven sequences — `verbs.json`)

| Verb | Sequence | k8s analogue |
|------|----------|--------------|
| `ship` | build → push → secrets → sync → pull → up → **health** | `apply` + `rollout status --watch` |
| `rollout` (=`redeploy`) | pull → up --force-recreate → health | `rollout restart` |
| `rollback [digest]` | pin prev digest → up → health | `rollout undo` |
| `<lifecycle.*>` | custom from `build.json` | Job/initContainer (exists, keep) |

---

## 3. Concrete work items

1. **Extract 3 pure functions** so they are callable standalone; existing fat steps call them (behavior byte-identical, bug history preserved):
   - `step_push` ← push half of `step_docker`
   - `step_pull` ← pull block of `step_compose`
   - `step_up` ← up block of `step_compose`
2. **`step-status.sh` (NEW, read-only):** for each `containers[].container_name` in `build.json`:
   - desired = `docker manifest inspect ghcr.io/<img>:<tag>` → platform manifest digest **for the VM's arch** (see §5)
   - observed = ssh VM `docker inspect --format '{{index .RepoDigests 0}}' <c>`
   - → `InSync | Drift`; plus `step_health` state rollup + `dist`-hash vs VM `.dist-hash`. Emits a compact table.
3. **`step-logs.sh` (NEW):** ssh VM `docker compose -f <compose> logs --tail ${N:-100} [--follow]`.
4. **`ship` calls `step_health`** as its final phase (today it only does a 3s `docker ps` glance — real gap).
5. **`verbs.json` (`1_configs/src/engine/libs/verbs.json`):** declares composite sequences; dispatcher reads it instead of hardcoding `ship`/`rollout`/`rollback` order. Atomic verbs stay 1:1 with functions (no verb-DSL — avoid over-engineering).
6. **Reconcile skip** upgrades from `.dist-hash` + `.image-changed` flag to: *skip iff `status` reports InSync && healthy*. Level-triggered, converges.

---

## 4. Dispatcher change (case block)

New atomic arms: `push | sync | pull | up | down | restart | status | logs`.
Composite arms (`ship | rollout | rollback`) resolve their step order from `verbs.json`.
`all`, `clean`, wrangler/terraform, and `lifecycle.*` arms unchanged.

---

## 5. The one sharp edge — multi-arch digest compare

`docker manifest inspect` returns the **index** digest; a VM's `RepoDigests` may hold the index *or* the per-arch manifest digest depending on the pull. `status` MUST compare the **platform manifest digest for the VM's arch** (oci-apps = arm64), read from `docker.arch` in `build.json`, not the index blindly — otherwise a correct deploy false-reports Drift. This is the only place digest logic must be careful.

---

## 6. Tester (FIRE rule 5)

Target: `aa-sui_etherpad` (low risk, has healthcheck).

1. `build.sh ship` → `build.sh status` asserts **InSync + healthy**.
2. `build.sh ship` again → skip fires ("reconciled") — idempotence/reconcile proven.
3. `ssh oci-apps docker stop etherpad` → `build.sh status` reports **Drift/stopped** — proves status observes reality, not a flag file.
4. `build.sh logs --tail 20` → returns lines.
5. `build.sh rollout` → back to InSync + healthy without a rebuild.

---

## 7. Non-goals (this phase)

- No rewrite of `step_docker` / `step_compose` internals (only extraction).
- No change to HM engine or repo-workflow engine.
- `diff` and `rollback` are stubs/phase-2 unless promoted.
