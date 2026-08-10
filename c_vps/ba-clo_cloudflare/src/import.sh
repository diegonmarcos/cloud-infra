#!/bin/sh
# Adopt existing Cloudflare DNS records into Terraform state.
#
# Idempotent — every import is gated on `terraform state list` so it's safe to
# call on every pipeline run. First run imports the world; subsequent runs are
# pure no-ops (the gate skips everything already in state).
#
# Hook point: 1_configs/src/deploy/scripts/cloud-ship-terraform-deploy-apply.sh
# calls `./import.sh` right after `terraform init`, before `plan`. Same
# pattern as c_vps/vps_oci/src/import.sh.
#
# Why this exists: CF terraform provider's `allow_overwrite=true` only resolves
# a single (name, type, content) match. With multi-value DNS (wildcard +
# extra_ips → multiple records per name) it fails with "didn't find an exact
# match" when content doesn't exactly match the target. Pre-importing each
# record by its CF id sidesteps the lookup entirely.
#
# CF record IDs sourced from `cf-records.json` (data-driven, not hardcoded in
# this script per CORE PRINCIPLE #6). To add a new record:
#   1. Find its CF id (curl + jq, or CF dashboard)
#   2. Add to cf-records.json with the terraform resource address as key
#   3. Re-run pipeline — import.sh picks it up automatically
set -u

cd "$(dirname "$0")"

# Zone ID from terraform.json (single source of truth).
ZONE_ID="$(jq -r '.account_id // empty' terraform.json 2>/dev/null)"
# Override: zone id is NOT account_id; it's a separate field. Pull from
# either dist/.secrets or env (TF_VAR_cloudflare_zone_id from GHA secrets).
[ -n "${TF_VAR_cloudflare_zone_id:-}" ] && ZONE_ID="$TF_VAR_cloudflare_zone_id"
[ -n "${CLOUDFLARE_ZONE_ID:-}" ]        && ZONE_ID="$CLOUDFLARE_ZONE_ID"
# Sentinel: fall back to the known zone id (data-driven would be ideal, but
# this matches the dashboard and rarely changes; surfaced if absent).
: "${ZONE_ID:=ff4335cc9c7de42e580d0dff9a0d70eb}"

# Pre-fetch state addresses ONCE.
STATE_ADDRS="$(terraform state list 2>/dev/null || true)"

tf_adopt_cf() {
  addr="$1"
  record_id="$2"
  if printf '%s\n' "$STATE_ADDRS" | grep -Fxq -- "$addr"; then
    echo "  SKIP  $addr (already in state)"
  else
    echo "  IMPORT $addr ← $record_id"
    terraform import "$addr" "${ZONE_ID}/${record_id}"
    STATE_ADDRS="$STATE_ADDRS
$addr"
  fi
}

echo "=== A Records (multi-value + per-record overrides) ==="
tf_adopt_cf 'cloudflare_record.a_records["api"]'         c17a25f69f5d7f80dbdf01b3a335cca1
tf_adopt_cf 'cloudflare_record.a_records["*"]'           bcb3ccb212704a2448b17a62e6e8ce0a
# NOTE: a_records["*-10.0.0.1"] (the public mesh-IP wildcard) was REMOVED —
# RFC1918 mesh IPs must not appear in public CF DNS (split-horizon: Hickory
# serves the wg0 mesh answer). If it remains in CF/state, terraform apply
# destroys it; do NOT re-import it.
tf_adopt_cf 'cloudflare_record.a_records["mail"]'        74a508b19674dd730f371e29a5073b5d

echo ""
echo "=== Done. Pipeline will now run terraform plan + apply ==="
