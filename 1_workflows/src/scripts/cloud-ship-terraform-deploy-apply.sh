#!/usr/bin/env bash
# ── Run terraform plan+apply for cloud providers + wrangler for CF worker ──
# Usage: ship-terraform.sh [project]
#   project: cloudflare, gcloud, oci, hetzner, cf-worker (omit for all)
set -euo pipefail

PROJECT="${1:-}"
REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT"
export CLOUD_ROOT="$REPO_ROOT"  # ensure-deps.sh / cloud-paths.sh read this

# ── Dependencies — sourced from shared lib ────────────────────────
# Was 3 inline `ensure_*` functions; consolidated into
# 1_workflows/src/libs/ensure-deps.sh on 2026-04-28 so any future engine
# (terraform, ship, gen-configs, …) gets the same idempotent bootstrap.
LIB_DIR="$REPO_ROOT/1_workflows/src/libs"
# shellcheck source=../libs/ensure-deps.sh
[ -f "$LIB_DIR/ensure-deps.sh" ] && . "$LIB_DIR/ensure-deps.sh"

# Local fallback for fresh clones where libs/ might not be deployed yet —
# defensive only; happy path uses the shared functions above.
if ! command -v ensure_sops >/dev/null 2>&1; then
  ensure_sops() {
    command -v sops >/dev/null 2>&1 && return
    echo "Installing sops..."
    curl -fsSL -o /tmp/sops https://github.com/getsops/sops/releases/download/v3.9.4/sops-v3.9.4.linux.amd64
    chmod +x /tmp/sops && sudo mv /tmp/sops /usr/local/bin/sops
  }
fi
if ! command -v ensure_terraform >/dev/null 2>&1; then
  ensure_terraform() {
    command -v terraform >/dev/null 2>&1 && return
    echo "Installing terraform..."
    curl -fsSL -o /tmp/tf.zip https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_linux_amd64.zip
    unzip -o /tmp/tf.zip -d /tmp && sudo mv /tmp/terraform /usr/local/bin/terraform
  }
fi
if ! command -v ensure_wrangler >/dev/null 2>&1; then
  # `wrangler` is baked into the cloud-builder image at image-build time,
  # driven by cloud/config.json:.deps.docker_npm (FIRE rule 4: data-driven,
  # rule 1: declarative). Runtime npm-install was retired 2026-05-07 — it
  # silently swallowed npm errors, version was unpinned, and ran every CI
  # invocation. If wrangler is missing here, the cloud-builder image is
  # stale; rebuild + push via:
  #   bash unix/cb_containers-builders/build.sh ship cloud-builder-x-deb-nixhm
  ensure_wrangler() {
    if ! command -v wrangler >/dev/null 2>&1; then
      echo "FATAL: wrangler not on PATH inside cloud-builder image." >&2
      echo "  Image is stale — rebuild via:" >&2
      echo "  bash unix/cb_containers-builders/build.sh ship cloud-builder-x-deb-nixhm" >&2
      exit 1
    fi
  }
fi

declare -A TF_DIRS=(
  [cloudflare]="c_vps/ba-clo_cloudflare/src"
  [gcloud]="c_vps/vps_gcloud/src"
  [oci]="c_vps/vps_oci/src"
  [hetzner]="c_vps/vps_hetzner/src"
)

OK=0; FAIL=0; SKIP=0; STATE_CHANGED=false

# ── Change detection ──
# On push events, CHANGES_* env vars indicate what changed.
# On workflow_dispatch, INPUT_PROJECT selects the target.
# Skip providers with no changes unless explicitly requested.
should_run() {
  local name="$1"
  # Explicit project filter always wins
  [ -n "$PROJECT" ] && { [ "$PROJECT" = "$name" ] && return 0 || return 1; }
  # On workflow_dispatch with no project filter, run all
  [ "${EVENT_NAME:-}" = "workflow_dispatch" ] && return 0
  # On push, check CHANGES_* env var (uppercase, hyphens to underscores)
  local var_name="CHANGES_$(echo "$name" | tr '[:lower:]-' '[:upper:]_')"
  local val="${!var_name:-false}"
  [ "$val" = "true" ]
}

# ── Cloudflare Worker (wrangler) ──
if should_run "cf-worker"; then
  WORKER_DIR="a_solutions/ba-clo_cloudflare-worker/src"
  if [ -d "$WORKER_DIR" ]; then
    echo "── Wrangler: cf-worker ($WORKER_DIR) ──"
    ensure_wrangler
    cd "$REPO_ROOT/$WORKER_DIR"
    if wrangler deploy; then
      echo "OK cf-worker"
      OK=$((OK + 1))
    else
      echo "FAIL cf-worker (deploy)"
      FAIL=$((FAIL + 1))
    fi
    cd "$REPO_ROOT"
  else
    echo "SKIP cf-worker (dir not found)"
    SKIP=$((SKIP + 1))
  fi
fi

# ── Terraform providers ──
for name in cloudflare gcloud oci hetzner; do
  if ! should_run "$name"; then
    continue
  fi

  dir="${TF_DIRS[$name]}"
  if [ ! -d "$dir" ]; then
    echo "SKIP $name (dir $dir not found)"
    SKIP=$((SKIP + 1))
    continue
  fi

  echo "── Terraform: $name ($dir) ──"
  ensure_sops
  ensure_terraform
  cd "$REPO_ROOT/$dir"

  # Decrypt tfstate from sops-encrypted file
  if [ -f terraform.tfstate.enc ] && [ ! -f terraform.tfstate ]; then
    sops -d --input-type json --output-type json terraform.tfstate.enc > terraform.tfstate
    echo "  Decrypted terraform.tfstate.enc"
  fi

  # Copy tfvars template if no tfvars exists (gitignored for security)
  if [ ! -f terraform.tfvars ] && [ -f terraform.tfvars.template ]; then
    # Strip placeholder lines — TF_VAR_ env vars from GHA secrets take precedence
    awk 'index($0, "INJECTED_FROM_SECRETS") == 0 && index($0, "CHANGE_ME") == 0' terraform.tfvars.template > terraform.tfvars
    echo "  Copied terraform.tfvars.template → terraform.tfvars (placeholders stripped)"
  fi

  tf_cleanup() { rm -f terraform.tfstate terraform.tfstate.backup terraform.tfvars tfplan; rm -rf .terraform; }
  terraform init -input=false || { echo "FAIL $name (init)"; FAIL=$((FAIL + 1)); tf_cleanup; cd "$REPO_ROOT"; continue; }
  terraform plan -input=false -out=tfplan || { echo "FAIL $name (plan)"; FAIL=$((FAIL + 1)); tf_cleanup; cd "$REPO_ROOT"; continue; }
  terraform apply -input=false -auto-approve tfplan || { echo "FAIL $name (apply)"; FAIL=$((FAIL + 1)); tf_cleanup; cd "$REPO_ROOT"; continue; }

  # Re-encrypt updated tfstate
  if [ -f terraform.tfstate ] && [ -f terraform.tfstate.enc ]; then
    cp terraform.tfstate terraform.tfstate.enc
    sops -e -i --input-type json --output-type json terraform.tfstate.enc
    STATE_CHANGED=true
    echo "  Re-encrypted terraform.tfstate.enc"
  fi

  tf_cleanup

  echo "OK $name"
  OK=$((OK + 1))
  cd "$REPO_ROOT"
done

# Commit updated tfstate.enc files back to repo
if [ "$STATE_CHANGED" = true ]; then
  echo "── Committing updated tfstate.enc files ──"
  git add c_vps/*/src/terraform.tfstate.enc
  if ! git diff --cached --quiet; then
    git config user.name "github-actions"
    git config user.email "actions@github.com"
    git commit -m "terraform: update encrypted tfstate"
    git pull --rebase
    git push
  fi
fi

echo "Terraform: $OK ok, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
