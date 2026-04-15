# Plan: Consolidate All Cloud Engines into `1_workflows/src/scripts/`

## Context

Shell-based infrastructure control plane for 5 VMs / 58 services. The engine is the sole orchestrator — `docker compose up -d --no-build --force-recreate` never rebuilds, only pulls pre-built GHCR images. Three-stage deploy: code image (GHCR), configs image (GHCR), secrets (rsync) — each independently hashed. GHA provides logging; container-init.sh is our boot tool, not a competing orchestrator.

**Already done (this session):**
- `workflows/` → `1_workflows/`, `cloud-data/` → `I_cloud-data/`, `tools/` → `II_tools/`
- `static/` → `cicd/`, `scripts-dagu/` created, stale files cleaned
- `build.sh workflow` flow fixed (src→dist→deploy, header injection, symlink always recreated)
- `config.json` bug fixed (`iproute2` → `ip`)
- README.md created with full hierarchy

---

## Bugs to Fix During Decomposition

| # | Bug | Fix Location | Fix |
|---|-----|-------------|-----|
| 1 | **Secrets hash missing** — secrets change but deploy skipped (dist hash matches) | `cloud-ship-container-step-secrets-decrypt.sh` | Write `.secrets-hash`. Ship pipeline: if secrets hash changed, force deploy even if dist unchanged. |
| 2 | **Idempotency gap** — `.dist-hash` written after deploy, before compose succeeds | `cloud-ship-container-engine.sh` | Write `.dist-hash` AFTER compose succeeds. Failed compose = next run retries. |
| 3 | **No arch verification** — docker push doesn't verify manifest matches declared arch | `cloud-ship-container-step-build-docker.sh` | `docker manifest inspect` after push, compare arch vs build.json. Fail on mismatch. |
| 4 | **SSH multiplex race** — parallel xargs workers fight for ControlMaster | `cloud-ship-ci-builder-dispatch.sh` | Pre-establish master with `-fNM`. Workers: `ControlMaster=no`, reuse via ControlPath only. |
| 5 | **REMOTE_BUILD is manual flag** — arch and build location decoupled | `cloud-ship-container-step-build-docker.sh` | Auto-select runner from runner manifest + declared arch. See Runner Manifest below. |

---

## Runner Manifest (Bug #5 Fix)

Declared in `config.json`:
```json
{
  "runners": {
    "arm64": { "alias": "oci-apps", "type": "ssh", "native": true },
    "amd64": { "alias": "gha", "type": "local", "native": true }
  }
}
```

Auto-select logic in `cloud-ship-container-step-build-docker.sh`:
```
DECLARED_ARCH = build.json docker.arch (arm64 / amd64)

if RUNNER == "runner-local" (explicit override):
    → build on current host
    → if host arch != declared arch → use --platform (QEMU)
    → if host arch == declared arch → native build
else (default auto):
    → look up config.json runners[DECLARED_ARCH]
    → if runner.type == "ssh" → build on runner.alias via SSH (native, fast)
    → if runner.type == "local" → build locally (native or QEMU)
```

`build.sh ship` from Surface (x86) for arm64 service → auto-selects `oci-apps` (SSH, native arm64).
`build.sh ship runner-local` from Surface → QEMU cross-build with `--platform linux/arm64`.
GHA runner (x86) for arm64 service → auto-selects `oci-apps` via SSH.

No more manual `REMOTE_BUILD` flag. No more silent wrong-arch builds.

---

## Architecture Notes

**Three-stage deploy with independent hashing:**
| Stage | Artifact | Hash File | Where |
|-------|----------|-----------|-------|
| Code image | `ghcr.io/.../service:latest` | `.docker-src-hash` | GHCR |
| Configs image | `ghcr.io/.../service-configs:latest` | (image digest) | GHCR |
| Secrets | `.secrets` env file | `.secrets-hash` (NEW) | rsync to VM |
| Dist (compose + config files) | `dist/` folder | `.dist-hash` | rsync to VM |

Each hash is independent. Each stage can be updated without touching others.

**Compose is pull-only:** `docker compose up -d --no-build --force-recreate` — never rebuilds on VM. Build step is completely separated from deploy step.

**Unified logging:** GHA run logs are primary. Future: append structured events to Loki or a simple JSON log per VM for ship operations outside GHA (CLI, Dagu).

---

## Naming Convention

```
cloud-<system>-<technology>-<action>-<detail>.sh
```

One flat folder. One `ls` shows everything. Prefixes ARE the hierarchy.

---

## Full Target File List (~50 scripts)

### Libraries (`cloud-ship-lib-*`)

| Script | Description |
|--------|-------------|
| `cloud-ship-lib.sh` | Core: CLOUD_ROOT, log(), log_error(), check_deps(), deps_binaries() |
| `cloud-ship-lib-ssh.sh` | ssh_cmd(), gcloud vs key detection, multiplexing setup |
| `cloud-ship-lib-deploy.sh` | deploy_to_vm(), rsync, rclone, manifest helpers |
| `cloud-ship-lib-config.sh` | get_vm_prop(), get_svc_prop(), get_all_services(), get_all_vms() |

### Container Engine (`cloud-ship-container-*`)
From `a_solutions/_engine.sh` (1316 lines → engine dispatcher + 13 step files)

| Script | Source | Description |
|--------|--------|-------------|
| `cloud-ship-container-engine.sh` | _engine.sh dispatch (~200 lines) | Config loading, case statement, ship pipeline phases. Symlinked by 58 services. Sources step files. **Bug #2: .dist-hash after compose.** |
| `cloud-ship-container-step-build-nix.sh` | `step_build()` | Nix flake → dist/ |
| `cloud-ship-container-step-build-docker.sh` | `step_docker()` | Docker build + push GHCR. **Bug #3: arch verify. Bug #5: auto-select runner.** |
| `cloud-ship-container-step-build-configs.sh` | `step_configs_push()` | Configs image push GHCR |
| `cloud-ship-container-step-build-compose.sh` | `step_compose_build()` | dockerfile_inline build + push |
| `cloud-ship-container-step-deploy-rsync.sh` | `step_deploy()` | Rsync dist/ → VM (manifest-based) |
| `cloud-ship-container-step-deploy-compose.sh` | `step_compose()` | `docker compose up -d --no-build --force-recreate` |
| `cloud-ship-container-step-deploy-health.sh` | `step_health()` | Post-deploy health probe |
| `cloud-ship-container-step-secrets-decrypt.sh` | `step_secrets()` | Sops decrypt → .secrets. **Bug #1: write .secrets-hash.** |
| `cloud-ship-container-step-clean.sh` | `step_clean_remote()` | Compare manifest vs remote, delete stale |
| `cloud-ship-container-step-docs.sh` | `step_docs()` | Build documentation |
| `cloud-ship-container-step-wrangler.sh` | `step_wrangler()` | Deploy Cloudflare Worker |
| `cloud-ship-container-step-lifecycle.sh` | `run_lifecycle()` | Custom lifecycle actions from build.json |

### Terraform Pipeline (`cloud-ship-terraform-*`)

| Script | Source | Description |
|--------|--------|-------------|
| `cloud-ship-terraform-deploy-apply.sh` | `step_terraform()` + `ship-terraform.sh` | Terraform init + apply |
| `cloud-ship-terraform-deploy-plan.sh` | `step_terraform_plan()` | Terraform plan (dry-run) |

### Nix Home-Manager Engine (`cloud-ship-nix-homemanager-*`)
From `b_infra/home-manager/_engine.sh` (572 lines → engine + 7 step files)

| Script | Source | Description |
|--------|--------|-------------|
| `cloud-ship-nix-homemanager-engine.sh` | _engine.sh dispatch (~100 lines) | Symlinked by 5 VMs. Sources step files. |
| `cloud-ship-nix-homemanager-step-build-flake.sh` | `step_build()` | Copy src → dist, resolve symlinks |
| `cloud-ship-nix-homemanager-step-build-docker.sh` | `step_docker_package()` | Package HM closure as Docker image |
| `cloud-ship-nix-homemanager-step-deploy-push.sh` | `step_docker_push()` | Push HM image to GHCR |
| `cloud-ship-nix-homemanager-step-deploy-activate.sh` | `step_compose()` | SSH activate HM on VM |
| `cloud-ship-nix-homemanager-step-deploy-rsync.sh` | `step_deploy()` | Rsync flake or nix copy closure |
| `cloud-ship-nix-homemanager-step-secrets-decrypt.sh` | `step_secrets()` | Sops decrypt for HM |
| `cloud-ship-nix-homemanager-step-pull-pilot.sh` | `step_pull_pilot()` | Check vm-pilot symlink |

### CI/CD Builder (`cloud-ship-ci-*`)

| Script | Old name | Description |
|--------|----------|-------------|
| `cloud-ship-ci-builder.sh` | `cloud-builder.sh` | CI entry point |
| `cloud-ship-ci-builder-secrets.sh` | `cloud-builder-secrets.sh` | SSH + SOPS setup from env |
| `cloud-ship-ci-builder-dispatch.sh` | `cloud-builder-ship.sh` | Per-VM parallel dispatcher. **Bug #4: SSH master pre-established.** |

### Orchestration (`cloud-ship-orchestrate-*`)

| Script | Source | Description |
|--------|--------|-------------|
| `cloud-ship-orchestrate-portable.sh` | `ship.sh` | Ship orchestrator (GHA/Dagu/CLI) |
| `cloud-ship-orchestrate-vm.sh` | `ship-vm.sh` (Dagu) | Ship all services for one VM |
| `cloud-ship-orchestrate-ghcr.sh` | `ship-ghcr.sh` (Dagu) | Build + push all GHCR images |
| `cloud-ship-orchestrate-profile.sh` | profile-ship logic | Profile-based tiered deploy |
| `cloud-ship-orchestrate-gen-configs.sh` | `ship-gen-configs.sh` | Generate cloud-data configs |
| `cloud-ship-orchestrate-build.sh` | `cmd_build()` | Build one or all services |
| `cloud-ship-orchestrate-ship.sh` | `cmd_ship()` | Ship one or all services |
| `cloud-ship-orchestrate-homemanager.sh` | `ship-home-manager.sh` (Dagu) | Ship HM to VM |

### Repo Management (`cloud-ship-repo-*`)

| Script | Source | Description |
|--------|--------|-------------|
| `cloud-ship-repo-deps.sh` | `cmd_deps()` | Install deps from config.json |
| `cloud-ship-repo-config-gen.sh` | `cmd_config()` | Generate cloud-data JSONs via tsx |
| `cloud-ship-repo-workflow-gen.sh` | `cmd_workflow()` + `1_workflows/build.sh` | Build workflows src→dist→.github |
| `cloud-ship-repo-secrets.sh` | `cmd_secrets()` | List/encrypt/decrypt secrets |
| `cloud-ship-repo-ssh.sh` | `cmd_ssh()` | SSH into a VM |
| `cloud-ship-repo-status.sh` | `cmd_status()` | Docker ps on VM |
| `cloud-ship-repo-restart.sh` | `cmd_restart()` | Restart service on VM |
| `cloud-ship-repo-compose.sh` | `cmd_compose()` | Docker compose up on VM |
| `cloud-ship-repo-clean.sh` | `cmd_clean()` | Remove all dist/ |

### Health & Testing (`cloud-health-*`)

| Script | Old name | Runner | Description |
|--------|----------|--------|-------------|
| `cloud-health-full.sh` | `health-full.sh` | GHA | Consolidated health (L1-L5) |
| `cloud-health-all-vms.sh` | `health-all-vms.sh` | Dagu | Health all VMs |
| `cloud-health-check-vm.sh` | `health-check-vm.sh` | Dagu | Single VM health |
| `cloud-health-http-private.sh` | `health-http-private.sh` | Dagu | Mesh DNS resolution |
| `cloud-health-http-public.sh` | `health-http-public.sh` | Dagu | Public URL checks |
| `cloud-health-mail-full.sh` | `health-mail-full.sh` | Dagu | Mail stack diagnostic |

---

## Phase 1: Rename + merge existing scripts (no logic changes)

### Step 1.1: Merge scripts-dagu/ into scripts/ with new names
9 `git mv` operations. Remove empty `scripts-dagu/`.

### Step 1.2: Rename existing GHA scripts with cloud- prefix
7 `git mv` operations.

### Step 1.3: Update cross-references
- Script-to-script calls (builder → secrets → dispatch)
- `cicd/*.yml` workflow references
- Dagu DAG references in `a_solutions/bc-obs_dagu/src/dags/gha/`

---

## Phase 2: Move + decompose engines + fix bugs

### Step 2.1: Decompose container engine (1316 lines → ~15 files)
1. `git mv a_solutions/_engine.sh 1_workflows/src/scripts/cloud-ship-container-engine.sh`
2. Extract each `step_*()` into its own `cloud-ship-container-step-*.sh`
3. Engine becomes dispatcher (~200 lines) that sources step files
4. Update 58 symlinks: `../_engine.sh` → `../../1_workflows/src/scripts/cloud-ship-container-engine.sh`
5. Fix bug #1: secrets hash in step-secrets-decrypt
6. Fix bug #2: .dist-hash after compose in engine
7. Fix bug #3: arch verify in step-build-docker
8. Fix bug #5: auto-select runner from manifest in step-build-docker

### Step 2.2: Decompose HM engine (572 lines → ~9 files)
1. `git mv b_infra/home-manager/_engine.sh 1_workflows/src/scripts/cloud-ship-nix-homemanager-engine.sh`
2. Extract each `step_*()` into its own file
3. Update 5 symlinks

### Step 2.3: Extract terraform steps from container engine

### Step 2.4: Fix SSH multiplex (bug #4) in `cloud-ship-ci-builder-dispatch.sh`

### Step 2.5: Add runner manifest to config.json

---

## Phase 3: Extract build.sh logic into scripts

### Step 3.1: Create libraries
- `cloud-ship-lib.sh` — thin core (logging, CLOUD_ROOT, check_deps)
- `cloud-ship-lib-ssh.sh` — SSH domain
- `cloud-ship-lib-deploy.sh` — deploy domain
- `cloud-ship-lib-config.sh` — config domain

### Step 3.2: Create 12 command scripts
Each sources `cloud-ship-lib.sh` + relevant domain libs.

### Step 3.3: Rewrite `cloud/build.sh` as pure dispatcher (~100 lines)
```sh
#!/bin/sh
CLOUD_ROOT="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$CLOUD_ROOT/1_workflows/src/scripts"
. "$SCRIPTS/cloud-ship-lib.sh"
[ "${1:-}" != "deps" ] && check_deps
case "${1:-help}" in
    deps)         sh "$SCRIPTS/cloud-ship-repo-deps.sh" "$@" ;;
    build)        sh "$SCRIPTS/cloud-ship-orchestrate-build.sh" "$@" ;;
    ship)         sh "$SCRIPTS/cloud-ship-orchestrate-ship.sh" "$@" ;;
    compose)      sh "$SCRIPTS/cloud-ship-repo-compose.sh" "$@" ;;
    ssh)          sh "$SCRIPTS/cloud-ship-repo-ssh.sh" "$@" ;;
    status)       sh "$SCRIPTS/cloud-ship-repo-status.sh" "$@" ;;
    restart)      sh "$SCRIPTS/cloud-ship-repo-restart.sh" "$@" ;;
    secrets)      sh "$SCRIPTS/cloud-ship-repo-secrets.sh" "$@" ;;
    config)       sh "$SCRIPTS/cloud-ship-repo-config-gen.sh" ;;
    workflow)     sh "$SCRIPTS/cloud-ship-repo-workflow-gen.sh" ;;
    clean)        sh "$SCRIPTS/cloud-ship-repo-clean.sh" ;;
    profile-ship) sh "$SCRIPTS/cloud-ship-orchestrate-profile.sh" "$@" ;;
    help|"")      usage ;;
esac
```

### Step 3.4: Remove `1_workflows/build.sh` (absorbed)

---

## Phase 4: Update references + regenerate

### Step 4.1: Update cicd/*.yml script name references
### Step 4.2: Update Dagu DAG references
### Step 4.3: Regenerate: `./build.sh workflow`

---

## Phase 5: Verification

1. Symlinks: 58 service + 5 HM resolve correctly
2. CLI: `./build.sh help|deps|workflow|secrets|config|clean|ssh|status`
3. Service engine: `a_solutions/bb-sec_caddy/build.sh all`
4. HM engine: `b_infra/home-manager/nixhm-sudo-oci-apps/build.sh build`
5. GHA chain: `bash .github/workflows/scripts/cloud-ship-ci-builder.sh ship gcp-proxy`
6. Workflow round-trip: `./build.sh workflow` → dist/ has all ~50 scripts with headers
7. Bug #3: ship arm64 service → verify arch in manifest after push
8. Bug #5: ship from x86 for arm64 → auto-selects runner-arm or QEMU

---

## Implementation Order

1. Phase 1.1 — merge scripts-dagu/ → scripts/ (git mv)
2. Phase 1.2 — rename existing scripts (git mv)
3. Phase 1.3 — update cross-references
4. Phase 2.1 — decompose + move container engine + fix bugs #1,#2,#3,#5
5. Phase 2.2 — decompose + move HM engine
6. Phase 2.3 — extract terraform steps
7. Phase 2.4 — fix SSH multiplex (bug #4)
8. Phase 2.5 — add runner manifest to config.json
9. Phase 3.1 — create libraries
10. Phase 3.2 — extract 12 command scripts from build.sh
11. Phase 3.3 — rewrite build.sh as dispatcher
12. Phase 3.4 — remove 1_workflows/build.sh
13. Phase 4 — update refs + regenerate
14. Phase 5 — verification
