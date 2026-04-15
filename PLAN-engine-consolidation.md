# Plan: Consolidate All Cloud Engines into `1_workflows/src/scripts/`

## Context

Shell-based infrastructure control plane for 5 VMs / 58 services. The engine is the sole orchestrator — `docker compose up -d --no-build --force-recreate` never rebuilds, only pulls pre-built GHCR images. Three-stage deploy: code image (GHCR), configs image (GHCR), secrets (rsync) — each independently hashed. GHA provides logging; container-init.sh is our boot tool, not a competing orchestrator.

---

## COMPLETED

### Phase 1: Repo restructure + script consolidation
- `workflows/` → `1_workflows/` (git mv + all refs)
- `cloud-data/` → `I_cloud-data/`, `tools/` → `II_tools/` (submodule renames)
- `static/` → `cicd/` (GHA workflow YAMLs)
- All scripts consolidated into `1_workflows/src/scripts/` with `cloud-ship-*`/`cloud-health-*` naming
- Both engines moved as-is: `a_solutions/_engine.sh` → `cloud-ship-container-engine.sh`, `b_infra/home-manager/_engine.sh` → `cloud-ship-nix-homemanager-engine.sh`
- 58 service + 5 HM symlinks updated
- Cross-references updated (script-to-script, cicd/*.yml, Dagu partial)
- `build.sh workflow`: src→dist→deploy for ALL files, header injection, symlink always recreated
- TS engine symlinks added (gen-cloud-data.ts, derive-cloud-data.ts, gen-gha-config.ts)
- `.gitmodules` uses HTTPS (not SSH)
- `setup-wireguard.sh` created (was missing)
- `config.json` bug fixed (`iproute2` → `ip`)
- README.md + this plan created
- Stale files cleaned (duplicate gitmodules, broken .ts symlinks, old hooks)
- **Tested**: local (service engine, HM engine, build.sh), GHA (Ship, GHCR images, Auto-sync), cloud-builder container (fresh clone)

### Phase 2: Universal cloud-builder launcher
- `cloud-builder.sh`: host-side launcher — extracted from image via `cat | sh -s`
- `compose.yaml`: declarative runtime config (mounts, network, env vars) — baked into image
- `entrypoint.sh`: universal dispatcher (ship/health/bash) — auto-detects secrets from env or mounts
- Dockerfile updated: COPY cloud-builder.sh + compose.yaml, usage LABEL
- ALL 4 GHA workflows that use cloud-builder now use `docker compose run` (ship, health, gen-configs, home-manager)
- cloud-builder image rebuilt + pushed to GHCR
- `build.sh` engine path fix for config.json + config.json symlink in src/
- **Universal command**: `docker run --rm <image> cat /opt/cloud-builder/cloud-builder.sh | sh -s ship oci-apps`
- **Tested**: local (help, passthrough, compose flow), GHA (Ship → gcp-proxy green)

---

## REMAINING

### Phase 3: Extract build.sh logic into scripts

**Goal**: `cloud/build.sh` becomes ~100-line pure dispatcher. All logic moves to `1_workflows/src/scripts/`.

#### Step 3.1: Create libraries
| Script | Description |
|--------|-------------|
| `cloud-ship-lib.sh` | Core: CLOUD_ROOT, log(), log_error(), check_deps(), deps_binaries() |
| `cloud-ship-lib-ssh.sh` | ssh_cmd(), gcloud vs key detection, multiplexing setup |
| `cloud-ship-lib-deploy.sh` | deploy_to_vm(), rsync, rclone, manifest helpers |
| `cloud-ship-lib-config.sh` | get_vm_prop(), get_svc_prop(), get_all_services(), get_all_vms() |

#### Step 3.2: Create 12 command scripts
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
| `cloud-ship-orchestrate-build.sh` | `cmd_build()` | Build one or all services |
| `cloud-ship-orchestrate-ship.sh` | `cmd_ship()` | Ship one or all services |
| `cloud-ship-orchestrate-profile.sh` | profile-ship logic | Profile-based tiered deploy |

#### Step 3.3: Rewrite `cloud/build.sh` as pure dispatcher (~100 lines)

#### Step 3.4: Remove `1_workflows/build.sh` (absorbed)

### Phase 4: Engine decomposition

**Goal**: Break 1316-line container engine and 572-line HM engine into engine dispatcher + step files.

#### Container engine → engine + 13 step files
| Script | Source | Description |
|--------|--------|-------------|
| `cloud-ship-container-engine.sh` | dispatch (~200 lines) | Config loading, case statement, ship pipeline phases |
| `cloud-ship-container-step-build-nix.sh` | `step_build()` | Nix flake → dist/ |
| `cloud-ship-container-step-build-docker.sh` | `step_docker()` | Docker build + push GHCR. **Bug #3 + #5 fix.** |
| `cloud-ship-container-step-build-configs.sh` | `step_configs_push()` | Configs image push GHCR |
| `cloud-ship-container-step-build-compose.sh` | `step_compose_build()` | dockerfile_inline build + push |
| `cloud-ship-container-step-deploy-rsync.sh` | `step_deploy()` | Rsync dist/ → VM |
| `cloud-ship-container-step-deploy-compose.sh` | `step_compose()` | `docker compose up -d --no-build --force-recreate` |
| `cloud-ship-container-step-deploy-health.sh` | `step_health()` | Post-deploy health probe |
| `cloud-ship-container-step-secrets-decrypt.sh` | `step_secrets()` | Sops decrypt. **Bug #1 fix.** |
| `cloud-ship-container-step-clean.sh` | `step_clean_remote()` | Manifest vs remote comparison |
| `cloud-ship-container-step-docs.sh` | `step_docs()` | Build documentation |
| `cloud-ship-container-step-wrangler.sh` | `step_wrangler()` | Deploy Cloudflare Worker |
| `cloud-ship-container-step-lifecycle.sh` | `run_lifecycle()` | Custom lifecycle actions |

#### HM engine → engine + 7 step files
| Script | Source | Description |
|--------|--------|-------------|
| `cloud-ship-nix-homemanager-engine.sh` | dispatch (~100 lines) | Config, strategy selection |
| `cloud-ship-nix-homemanager-step-build-flake.sh` | `step_build()` | Copy src → dist |
| `cloud-ship-nix-homemanager-step-build-docker.sh` | `step_docker_package()` | Package HM as Docker image |
| `cloud-ship-nix-homemanager-step-deploy-push.sh` | `step_docker_push()` | Push HM image to GHCR |
| `cloud-ship-nix-homemanager-step-deploy-activate.sh` | `step_compose()` | SSH activate HM on VM |
| `cloud-ship-nix-homemanager-step-deploy-rsync.sh` | `step_deploy()` | Rsync flake or nix copy |
| `cloud-ship-nix-homemanager-step-secrets-decrypt.sh` | `step_secrets()` | Sops decrypt for HM |
| `cloud-ship-nix-homemanager-step-pull-pilot.sh` | `step_pull_pilot()` | Check vm-pilot symlink |

#### Terraform steps (extract from container engine)
| Script | Source | Description |
|--------|--------|-------------|
| `cloud-ship-terraform-deploy-apply.sh` | `step_terraform()` | Terraform init + apply |
| `cloud-ship-terraform-deploy-plan.sh` | `step_terraform_plan()` | Terraform plan |

### Phase 5: Bug fixes (during decomposition)

| # | Bug | Fix Location | Fix |
|---|-----|-------------|-----|
| 1 | **Secrets hash missing** | `cloud-ship-container-step-secrets-decrypt.sh` | Write `.secrets-hash`. Ship pipeline: if secrets hash changed, force deploy. |
| 2 | **Idempotency gap** | `cloud-ship-container-engine.sh` | Write `.dist-hash` AFTER compose succeeds. |
| 3 | **No arch verification** | `cloud-ship-container-step-build-docker.sh` | `docker manifest inspect` after push. |
| 4 | **SSH multiplex race** | `cloud-ship-ci-builder-dispatch.sh` | Pre-establish master, workers ControlMaster=no. |
| 5 | **REMOTE_BUILD manual** | `cloud-ship-container-step-build-docker.sh` | Auto-select runner from manifest. |

### Runner Manifest (Bug #5)

```json
// config.json
{
  "runners": {
    "arm64": { "alias": "oci-apps", "type": "ssh", "native": true },
    "amd64": { "alias": "gha", "type": "local", "native": true }
  }
}
```

Auto-select: `declared_arch == host_arch → local`, `arm64 on x86 + oci-apps reachable → runner-arm`, explicit `runner-local` → QEMU.

### Phase 6: Cleanup

- Update Dagu DAGs (`a_solutions/bc-obs_dagu/src/dags/gha/`) to new script names
- Consolidate 8 GHA workflows → 3 (ship.yml + ship-ci-image.yml + sync-submodules.yml)
- Add `gen-configs` and `ship-hm` as commands in entrypoint.sh (currently only ship/health/bash)

---

## Implementation Order

1. Phase 3.1 — create libraries
2. Phase 3.2 — extract 12 command scripts
3. Phase 3.3 — rewrite build.sh as dispatcher
4. Phase 3.4 — remove 1_workflows/build.sh
5. Phase 4 — decompose container engine + HM engine
6. Phase 5 — bug fixes (#1-#5)
7. Phase 6 — Dagu + GHA consolidation
