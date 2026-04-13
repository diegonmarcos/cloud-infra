#!/usr/bin/env bash
# ── Run terraform plan+apply for cloud providers ──
# Usage: ship-terraform.sh [project]
#   project: cloudflare, gcloud, oci, hetzner (omit for all)
set -euo pipefail

PROJECT="${1:-}"
REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT"

# ── Dependencies ──
if ! command -v sops >/dev/null 2>&1; then
  echo "Installing sops..."
  curl -fsSL -o /tmp/sops https://github.com/getsops/sops/releases/download/v3.9.4/sops-v3.9.4.linux.amd64
  chmod +x /tmp/sops && sudo mv /tmp/sops /usr/local/bin/sops
fi

if ! command -v terraform >/dev/null 2>&1; then
  echo "Installing terraform..."
  curl -fsSL -o /tmp/tf.zip https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_linux_amd64.zip
  unzip -o /tmp/tf.zip -d /tmp && sudo mv /tmp/terraform /usr/local/bin/terraform
fi

declare -A TF_DIRS=(
  [cloudflare]="c_vps/ba-clo_cloudflare/src"
  [gcloud]="c_vps/vps_gcloud/src"
  [oci]="c_vps/vps_oci/src"
  [hetzner]="c_vps/vps_hetzner/src"
)

OK=0; FAIL=0; SKIP=0; STATE_CHANGED=false

for name in cloudflare gcloud oci hetzner; do
  if [ -n "$PROJECT" ] && [ "$PROJECT" != "$name" ]; then
    continue
  fi

  dir="${TF_DIRS[$name]}"
  if [ ! -d "$dir" ]; then
    echo "SKIP $name (dir $dir not found)"
    SKIP=$((SKIP + 1))
    continue
  fi

  echo "── Terraform: $name ($dir) ──"
  cd "$REPO_ROOT/$dir"

  # Decrypt tfstate from sops-encrypted file
  if [ -f terraform.tfstate.enc ] && [ ! -f terraform.tfstate ]; then
    sops -d --input-type json --output-type json terraform.tfstate.enc > terraform.tfstate
    echo "  Decrypted terraform.tfstate.enc"
  fi

  # Copy tfvars template if no tfvars exists (gitignored for security)
  if [ ! -f terraform.tfvars ] && [ -f terraform.tfvars.template ]; then
    # Strip placeholder lines — TF_VAR_ env vars from GHA secrets take precedence
    awk 'index($0, "INJECTED_FROM_SECRETS") == 0' terraform.tfvars.template > terraform.tfvars
    echo "  Copied terraform.tfvars.template → terraform.tfvars (placeholders stripped)"
  fi

  terraform init -input=false || { echo "FAIL $name (init)"; FAIL=$((FAIL + 1)); cd "$REPO_ROOT"; continue; }
  terraform plan -input=false -out=tfplan || { echo "FAIL $name (plan)"; FAIL=$((FAIL + 1)); cd "$REPO_ROOT"; continue; }
  terraform apply -input=false -auto-approve tfplan || { echo "FAIL $name (apply)"; FAIL=$((FAIL + 1)); cd "$REPO_ROOT"; continue; }

  # Re-encrypt updated tfstate
  if [ -f terraform.tfstate ] && [ -f terraform.tfstate.enc ]; then
    cp terraform.tfstate terraform.tfstate.enc
    sops -e -i --input-type json --output-type json terraform.tfstate.enc
    STATE_CHANGED=true
    echo "  Re-encrypted terraform.tfstate.enc"
  fi

  echo "OK $name"
  OK=$((OK + 1))
  cd "$REPO_ROOT"
done

# Commit updated tfstate.enc files back to repo
if [ "$STATE_CHANGED" = true ]; then
  echo "── Committing updated tfstate.enc files ──"
  git add c_vps/*/src/terraform.tfstate.enc
  if ! git diff --cached --quiet; then
    git -c user.name="github-actions" -c user.email="actions@github.com" \
      commit -m "terraform: update encrypted tfstate"
    git push
  fi
fi

echo "Terraform: $OK ok, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
