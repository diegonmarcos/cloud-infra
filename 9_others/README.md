# 9_others — repo-universal config

Single source of truth for everything this repository installs into itself:
git behaviour, GitHub Actions, and editor/agent dotfiles. Nothing here is
fleet-specific — the derive job that produces `build-*.json` lives in
`1_cloud-configs/`.

```
src/
  git/    gitconfig gitattributes gitignore gitmodules + hooks/
  gha/    cicd/ (workflows)  actions/ (composite)  scripts/ (ship engine)
          ops/ (run-by-hand: health, cgc-db, git, audit)  flake.{nix,lock}
  apps/   claude/ vscode/ obsidian/ + manifest.json
  lib/    shell libs shared across modules (inject-header, ensure-deps, …)
  test/   the tester suite
```

Everything under `.github/` is **generated output** — never edit it directly.
Since the 1_cloud-configs split, `.github/` and `dist/` each have exactly one
owner, so `build.sh` wipes and rebuilds `dist/` rather than hand-listing the
subtrees it owns.

```
build.sh workflow   →   src/  →  dist/  →  .github/ + repo root
```

---

## Directory Structure

```
9_others/
├── build.sh                    # Workflow engine (src → dist → deploy)
├── README.md                   # This file
├── src/                        # SOURCE — edit here
│   ├── scripts/                # All executable scripts (see hierarchy below)
│   ├── cicd/                   # GHA workflow YAMLs (deployed → .github/workflows/)
│   ├── actions/                # GHA composite actions (deployed → .github/actions/)
│   ├── hooks/                  # Git hooks (deployed via gitconfig hooksPath)
│   ├── modules/                # Git submodule config (deployed → .gitmodules)
│   ├── gitconfig               # Repo git config (deployed → .gitconfig)
│   └── cloud-builder/          # Cloud-builder Docker image source
└── dist/                       # GENERATED — do not edit (has read-only headers)
    ├── scripts/                # → .github/workflows/scripts (symlink)
    ├── cicd/                   # → .github/workflows/*.yml
    ├── actions/                # → .github/actions/
    ├── hooks/                  # → via .gitconfig core.hooksPath
    ├── modules/                # → .gitmodules
    └── gitconfig               # → .gitconfig
```

---

## Scripts Hierarchy

All scripts live in `src/gha/scripts/` and follow the naming convention:

```
cloud-<system>-<technology>-<action>-<tool>.sh
```

### `cloud-ship-*` — The Ship System (build, deploy, CI/CD)

#### Container Pipeline (`cloud-ship-container-*`)
Per-service engine: nix flake → Docker image → deploy to VM → compose up

| Script | Action | Description |
|--------|--------|-------------|
| `cloud-ship-container-engine.sh` | — | Per-service build engine (symlinked by 58 services as build.sh) |
| `cloud-ship-container-build-nix.sh` | build | Nix flake → dist/ (docker-compose.yml, configs) |
| `cloud-ship-container-build-docker.sh` | build | Docker build + push to GHCR |
| `cloud-ship-container-build-configs.sh` | build | Configs image push to GHCR |
| `cloud-ship-container-build-compose.sh` | build | dockerfile_inline image build |
| `cloud-ship-container-deploy-rsync.sh` | deploy | Rsync dist/ → VM:/opt/containers/ |
| `cloud-ship-container-deploy-compose.sh` | deploy | Docker compose up -d on VM |
| `cloud-ship-container-deploy-health.sh` | deploy | Post-deploy health probe |
| `cloud-ship-container-secrets-decrypt.sh` | secrets | Sops decrypt → dist/.secrets |
| `cloud-ship-container-clean.sh` | clean | Remove dist/ + remote stale files |

#### Terraform Pipeline (`cloud-ship-terraform-*`)
Infrastructure as Code: Terraform + Cloudflare Workers

| Script | Action | Description |
|--------|--------|-------------|
| `cloud-ship-terraform-deploy-apply.sh` | deploy | Terraform init + apply |
| `cloud-ship-terraform-deploy-plan.sh` | deploy | Terraform plan (dry-run) |
| `cloud-ship-terraform-deploy-wrangler.sh` | deploy | Cloudflare Worker deploy via wrangler |

#### Nix Home-Manager Pipeline (`cloud-ship-nix-homemanager-*`)
Per-VM system configuration: build HM flake → package → deploy → activate

| Script | Action | Description |
|--------|--------|-------------|
| `cloud-ship-nix-homemanager-engine.sh` | — | Per-VM HM engine (symlinked by 5 VMs as build.sh) |
| `cloud-ship-nix-homemanager-build-flake.sh` | build | Copy src → dist, resolve symlinks |
| `cloud-ship-nix-homemanager-build-docker.sh` | build | Package HM closure as Docker image |
| `cloud-ship-nix-homemanager-deploy-push.sh` | deploy | Push HM image to GHCR |
| `cloud-ship-nix-homemanager-deploy-activate.sh` | deploy | SSH activate HM on VM |
| `cloud-ship-nix-homemanager-secrets-decrypt.sh` | secrets | Sops decrypt for HM |

#### Orchestration (`cloud-ship-orchestrate-*`)
Multi-service and multi-VM coordination

| Script | Action | Description |
|--------|--------|-------------|
| `cloud-ship-orchestrate-portable.sh` | — | Ship orchestrator (GHA/Dagu/CLI) |
| `cloud-ship-orchestrate-vm.sh` | — | Ship all services for one VM |
| `cloud-ship-orchestrate-ghcr.sh` | — | Build + push all GHCR images |
| `cloud-ship-orchestrate-profile.sh` | — | Profile-based tiered deployment |
| `cloud-ship-orchestrate-gen-configs.sh` | — | Generate cloud-data config JSONs |

#### CI/CD Builder (`cloud-ship-ci-*`)
Scripts that run inside the cloud-builder Docker container on GHA runners

| Script | Action | Description |
|--------|--------|-------------|
| `cloud-ship-ci-builder.sh` | — | CI entry point (dispatches to other scripts) |
| `cloud-ship-ci-builder-secrets.sh` | secrets | Setup SSH keys + SOPS age key from env |
| `cloud-ship-ci-builder-dispatch.sh` | — | Per-VM parallel service dispatcher |

#### Repo Management (`cloud-ship-repo-*`)
Repository-level commands (called by `cloud/build.sh` dispatcher)

| Script | Action | Description |
|--------|--------|-------------|
| `cloud-ship-lib.sh` | — | Shared library: logging, config reading, SSH, deploy helpers |
| `cloud-ship-repo-deps.sh` | — | Install all deps from config.json (nix/apt/npm) |
| `cloud-ship-repo-config-gen.sh` | — | Generate cloud-data JSONs via tsx |
| `cloud-ship-repo-workflow-gen.sh` | — | Build workflows src → dist → .github/ |
| `cloud-ship-repo-secrets.sh` | — | List/encrypt/decrypt/edit service secrets |
| `cloud-ship-repo-ssh.sh` | — | SSH into a VM |
| `cloud-ship-repo-status.sh` | — | Docker ps on a VM |
| `cloud-ship-repo-restart.sh` | — | Restart a service on VM |
| `cloud-ship-repo-clean.sh` | — | Remove all dist/ folders |

---

### `cloud-health-*` — Health & Testing

Monitoring and validation scripts (used by GHA health workflow + Dagu DAGs)

| Script | Runner | Description |
|--------|--------|-------------|
| `cloud-health-full.sh` | GHA | Consolidated health check (L1-L5: VM, URLs, DNS, TLS, APIs) |
| `cloud-health-all-vms.sh` | Dagu | Trigger health checks across all VMs |
| `cloud-health-check-vm.sh` | Dagu | Single VM health (container status + ports) |
| `cloud-health-http-private.sh` | Dagu | WireGuard mesh .app DNS resolution |
| `cloud-health-http-public.sh` | Dagu | Public HTTP endpoint checks |
| `cloud-health-mail-full.sh` | Dagu | Full mail stack diagnostic |

---

## CI/CD Workflows (`src/gha/cicd/`)

GHA workflow YAML definitions. Deployed to `.github/workflows/`.

| Workflow | Trigger | Description |
|----------|---------|-------------|
| `ship.yml` | Push to `a_solutions/*/src/` | Detect changes → ship to VMs via cloud-builder |
| `ship-ci-image.yml` | Push to `9_others/src/cloud-builder/` | Rebuild cloud-builder Docker image |
| `ship-gen-configs.yml` | Push to config sources | Regenerate cloud-data configs |
| `ship-ghcr-images.yml` | Manual | Build + push all Docker images to GHCR |
| `ship-home-manager.yml` | Push to `b_infra/` | Deploy HM to VMs |
| `ship-terraform.yml` | Push to terraform sources | Terraform apply |
| `health.yml` | Cron + manual | Consolidated health check |
| `sync-submodules.yml` | Push | Sync cloud-data + tools submodules |

---

## Actions (`src/actions/`)

GHA composite actions. Deployed to `.github/actions/`.

| Action | Description |
|--------|-------------|
| `setup-deps/` | Install build dependencies (nix, node, tools) |

---

## Hooks (`src/hooks/`)

Git hooks. Deployed to `dist/hooks/`, referenced via `.gitconfig` `core.hooksPath`.

| Hook | Description |
|------|-------------|
| `pre-commit` | Block secrets from reaching commits (reinforces .gitignore) |

---

## Modules (`src/modules/`)

Git configuration files deployed to repo root.

| File | Deployed to | Description |
|------|-------------|-------------|
| `gitmodules` | `.gitmodules` | Submodule definitions (I_cloud-data, II_tools) |

---

## Call Chain: GHA Ship Pipeline

```
1. Push to main (a_solutions/*/src/**)
   │
2. ship.yml → detect job
   │  Reads I_cloud-data/cloud-data-gha-config.json
   │  git diff → changed dirs → group by VM → matrix
   │
3. ship.yml → ship job (1 per VM, max 5 parallel)
   │  docker run cloud-builder-x-deb-nixhm
   │  git clone repo inside container
   │
4. cloud-ship-ci-builder.sh
   │  → cloud-ship-ci-builder-secrets.sh (SSH + SOPS)
   │  → cloud-ship-ci-builder-dispatch.sh (per-VM)
   │
5. cloud-ship-ci-builder-dispatch.sh
   │  Reads gha-config → services for this VM
   │  Filters by CHANGED_DIRS
   │  Pre-stages cloud-data into services
   │  xargs -P parallel:
   │
6. a_solutions/<dir>/build.sh ship
   │  (symlink → cloud-ship-container-engine.sh)
   │
   ├─ Phase 1: build (nix flake → dist/)
   ├─ Phase 2: 4 parallel (docker + configs + compose-build + secrets)
   └─ Phase 3: deploy + compose (skip if unchanged)
```

---

## Symlinks

| From | To | Count |
|------|----|-------|
| `a_solutions/*/build.sh` | `../../9_others/src/deploy/scripts/cloud-ship-container-engine.sh` | 58 |
| `b_infra/*/build.sh` | `../../../9_others/src/deploy/scripts/cloud-ship-nix-homemanager-engine.sh` | 5 |
| `.github/workflows/scripts` | `../../1_cicd/dist/scripts` | 1 |
