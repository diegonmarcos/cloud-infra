#!/bin/sh
# Adopt existing OCI resources into Terraform state.
# Idempotent — every import is gated on `terraform state list` so it's safe to
# call on every pipeline run. First run imports the world; subsequent runs are
# pure no-ops (the gate skips everything already in state).
#
# Hook point: cloud-ship-terraform-deploy-apply.sh calls `./import.sh` right
# after `terraform init`, before `plan`. Same pattern as the wrangler hook.
#
# DO NOT add ad-hoc `terraform import` calls outside this file — every
# pre-existing resource adoption belongs here.
set -u

cd "$(dirname "$0")"

NS="axpmn3qtq4ig"
BUDGET_ID="ocid1.budget.oc1.eu-marseille-1.amaaaaaauadvczaahk3wenhiyffruiliejvkc5uvfgikdpoe7opikgitocta"

# Pre-fetch the state addresses ONCE — much cheaper than calling
# `terraform state list` per import (each call re-reads the state file).
STATE_ADDRS="$(terraform state list 2>/dev/null || true)"

tf_adopt() {
  addr="$1"
  id="$2"
  if printf '%s\n' "$STATE_ADDRS" | grep -Fxq -- "$addr"; then
    echo "  SKIP  $addr (already in state)"
  else
    echo "  IMPORT $addr"
    terraform import "$addr" "$id"
    STATE_ADDRS="$STATE_ADDRS
$addr"
  fi
}

echo "=== VCN + Networking ==="
tf_adopt oci_core_vcn.main \
  ocid1.vcn.oc1.eu-marseille-1.amaaaaaauadvczaayaj5pwctlnw7uvxufo3iumrrjogoc52dcnozrojvivna
tf_adopt oci_core_internet_gateway.main \
  ocid1.internetgateway.oc1.eu-marseille-1.aaaaaaaafycgi5xcwzzghl2mfz5wutigunklobtajwkbq5l4sg4ayo2gx57q
tf_adopt oci_core_default_route_table.main \
  ocid1.routetable.oc1.eu-marseille-1.aaaaaaaaousfgs3ya74kb3wa2ly6o4s36x25igr6j3dcmg4dtslzggh4k37a
tf_adopt oci_core_default_security_list.main \
  ocid1.securitylist.oc1.eu-marseille-1.aaaaaaaapjyzyvoi3hodcgdtbvajvsubmobwknce4h3rxqitje7ocfht55jq
tf_adopt oci_core_subnet.main \
  ocid1.subnet.oc1.eu-marseille-1.aaaaaaaapz6g4htlyisp45zplqi47t3mms4noceyqebb5huhccrlt432ugeq

echo ""
echo "=== Compute Instances (for_each key = terraform.json .instances[].key) ==="
tf_adopt 'oci_core_instance.vms["mail_server"]' \
  ocid1.instance.oc1.eu-marseille-1.anwxeljruadvczacbwylmkqr253ay7binepapgsyopllfayovkzaky6oigbq
tf_adopt 'oci_core_instance.vms["analytics_server"]' \
  ocid1.instance.oc1.eu-marseille-1.anwxeljruadvczacgwg5rkrjyomuxvjtvtuk5xrbmy7hmslwn4pse4kw5jkq
tf_adopt 'oci_core_instance.vms["apps_server"]' \
  ocid1.instance.oc1.eu-marseille-1.anwxeljruadvczacj7dfxl7uifar574je7fzlvtdjp4ghljdwuwdemsdbiva

echo ""
echo "=== Object Storage (for_each key = bucket name) ==="
tf_adopt 'oci_objectstorage_bucket.buckets["cloud-backups-binaries-medias"]' \
  "n/${NS}/b/cloud-backups-binaries-medias"
tf_adopt 'oci_objectstorage_bucket.buckets["cloud-backups-db"]' \
  "n/${NS}/b/cloud-backups-db"
tf_adopt 'oci_objectstorage_bucket.buckets["cloud-backups-media"]' \
  "n/${NS}/b/cloud-backups-media"
tf_adopt 'oci_objectstorage_bucket.buckets["cloud-backups-non-binaries"]' \
  "n/${NS}/b/cloud-backups-non-binaries"
tf_adopt 'oci_objectstorage_bucket.buckets["my-photos"]' \
  "n/${NS}/b/my-photos"

echo ""
echo "=== Email Senders (for_each key = email address) ==="
tf_adopt 'oci_email_sender.senders["me@diegonmarcos.com"]' \
  ocid1.emailsender.oc1.eu-marseille-1.amaaaaaauadvczaaumrpqz622tzkrekelr2qgsspgazxdfmbi4dtmknjay2q
tf_adopt 'oci_email_sender.senders["no-reply@diegonmarcos.com"]' \
  ocid1.emailsender.oc1.eu-marseille-1.amaaaaaauadvczaaorpuusj6j7pevcsugax4v47bou6u3drmobzrbzh7ktba

echo ""
echo "=== Budget + Alert Rules ==="
tf_adopt oci_budget_budget.main "$BUDGET_ID"
tf_adopt 'oci_budget_alert_rule.alerts["50pct-spend-alert"]' \
  "budgets/${BUDGET_ID}/alertRules/ocid1.alertrule.oc1.eu-marseille-1.amaaaaaauadvczaam6k7hbckup42jnfi6f4fx7ntqn27onmjrg63ujpd43ca"
tf_adopt 'oci_budget_alert_rule.alerts["90pct-spend-alert"]' \
  "budgets/${BUDGET_ID}/alertRules/ocid1.alertrule.oc1.eu-marseille-1.amaaaaaauadvczaag2fpnzkgnrxyg6gse4jhbw4dperqfpuzicgqfb5ss46q"
tf_adopt 'oci_budget_alert_rule.alerts["100pct-spend-alert"]' \
  "budgets/${BUDGET_ID}/alertRules/ocid1.alertrule.oc1.eu-marseille-1.amaaaaaauadvczaajyzmliqrvpuchjrnbaoi32c22bueaklesptsh7h2v7nq"

echo ""
echo "=== Done. Pipeline will now run terraform plan + apply ==="
