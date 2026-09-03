#!/bin/sh
# Adopt pre-existing GCP resources into Terraform state.
#
# Idempotent — every import is gated on `terraform state list`, so it is safe
# to call on every pipeline run. Already-tracked resources are skipped.
#
# Hook point: 9_others/src/deploy/scripts/cloud-ship-terraform-deploy-apply.sh
# calls `./import.sh` right after `terraform init`, before `plan`. Same
# pattern as c_vps/vps_oci/src/import.sh and c_vps/ba-clo_cloudflare/src/import.sh.
#
# Why this exists: a firewall created out-of-band (gcloud console) OR by a
# prior apply whose state-commit-back failed lives in GCP but not in state.
# `terraform apply` then hits "Error 409: ... already exists, alreadyExists".
# Pre-importing each by its deterministic id sidesteps it.
#
# Fully data-driven (CORE PRINCIPLE #6): firewall names come from
# terraform.json `.firewall_rules[]` and the project from `.provider.project_id`
# (TF_VAR_gcp_project_id env overrides). The GCP firewall id is always
# `projects/<project>/global/firewalls/<name>` — no hardcoded ids.
set -u

cd "$(dirname "$0")"

PROJECT="$(jq -r '.provider.project_id // empty' terraform.json 2>/dev/null)"
[ -n "${TF_VAR_gcp_project_id:-}" ]   && PROJECT="$TF_VAR_gcp_project_id"
[ -n "${GOOGLE_PROJECT:-}" ]          && PROJECT="$GOOGLE_PROJECT"

if [ -z "$PROJECT" ]; then
  echo "  WARN: no project id (terraform.json .provider.project_id) — skipping import" >&2
  exit 0
fi

# Pre-fetch state addresses ONCE.
STATE_ADDRS="$(terraform state list 2>/dev/null || true)"

tf_adopt() {
  addr="$1"
  id="$2"
  if printf '%s\n' "$STATE_ADDRS" | grep -Fxq -- "$addr"; then
    echo "  SKIP  $addr (already in state)"
  else
    echo "  IMPORT $addr ← $id"
    terraform import "$addr" "$id"
    STATE_ADDRS="$STATE_ADDRS
$addr"
  fi
}

echo "=== Compute firewall rules (data-driven from terraform.json) ==="
for name in $(jq -r '.firewall_rules[]?.name // empty' terraform.json 2>/dev/null); do
  [ -n "$name" ] || continue
  tf_adopt "google_compute_firewall.rules[\"$name\"]" \
    "projects/${PROJECT}/global/firewalls/${name}"
done

# Static IPs + instances — added 2026-09-03 after gcp-gpu-embed hit the exact
# 409-alreadyExists this script exists to prevent: the create SUCCEEDED in
# GCP after terraform's own wait-for-create had already given up (a GPU
# zonal-stockout retry that resolved itself moments too late) and the state-
# persistence fix (fb8fc6e51) committed whatever local tfstate existed AT
# THAT MOMENT — before the operation had actually finished, so the resource
# was never recorded. Next apply then tried to create it again -> 409.
# Un-importable resources (declared but genuinely not created yet, e.g. the
# very first apply of a brand new instance) just fail this one `terraform
# import` call and the loop continues — same tolerance the firewall loop
# above already relies on (no `set -e`; the caller ignores this script's own
# exit code). Region for addresses: static_ips[].region field. Zone for
# instances: per-instance terraform.json .zone, falling back to
# .provider.zone — same resolution main.tf's `zone = try(...)` uses.
PROVIDER_ZONE="$(jq -r '.provider.zone // empty' terraform.json 2>/dev/null)"

echo ""
echo "=== Static IPs (data-driven from terraform.json) ==="
for name in $(jq -r '.static_ips[]?.name // empty' terraform.json 2>/dev/null); do
  [ -n "$name" ] || continue
  region="$(jq -r --arg n "$name" '.static_ips[] | select(.name==$n) | .region // empty' terraform.json 2>/dev/null)"
  [ -n "$region" ] || continue
  tf_adopt "google_compute_address.ips[\"$name\"]" \
    "projects/${PROJECT}/regions/${region}/addresses/${name}"
done

echo ""
echo "=== Compute instances (data-driven from terraform.json) ==="
for name in $(jq -r '.instances[]?.name // empty' terraform.json 2>/dev/null); do
  [ -n "$name" ] || continue
  zone="$(jq -r --arg n "$name" '.instances[] | select(.name==$n) | .zone // empty' terraform.json 2>/dev/null)"
  [ -n "$zone" ] || zone="$PROVIDER_ZONE"
  [ -n "$zone" ] || continue
  tf_adopt "google_compute_instance.vms[\"$name\"]" \
    "projects/${PROJECT}/zones/${zone}/instances/${name}"
done

echo ""
echo "=== Done. Pipeline will now run terraform plan + apply ==="
