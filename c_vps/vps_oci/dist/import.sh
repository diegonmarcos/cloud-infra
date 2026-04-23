#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : c_vps/vps_oci/src/import.sh
# ║   Engine : 1_workflows/src/scripts/cloud-ship-terraform-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Import existing OCI resources into Terraform state.
# Run AFTER: cd src && terraform init
# Safe: import only reads, never modifies infrastructure.
# After: terraform plan → should show 0 changes.
set -eu

# Runs from dist/ (engine copies src/ → dist/)
# Can also run standalone from src/
cd "$(dirname "$0")"

NS="axpmn3qtq4ig"

echo "=== VCN + Networking ==="
terraform import oci_core_vcn.main \
  ocid1.vcn.oc1.eu-marseille-1.amaaaaaauadvczaayaj5pwctlnw7uvxufo3iumrrjogoc52dcnozrojvivna

terraform import oci_core_internet_gateway.main \
  ocid1.internetgateway.oc1.eu-marseille-1.aaaaaaaafycgi5xcwzzghl2mfz5wutigunklobtajwkbq5l4sg4ayo2gx57q

terraform import oci_core_default_route_table.main \
  ocid1.routetable.oc1.eu-marseille-1.aaaaaaaaousfgs3ya74kb3wa2ly6o4s36x25igr6j3dcmg4dtslzggh4k37a

terraform import oci_core_default_security_list.main \
  ocid1.securitylist.oc1.eu-marseille-1.aaaaaaaapjyzyvoi3hodcgdtbvajvsubmobwknce4h3rxqitje7ocfht55jq

terraform import oci_core_subnet.main \
  ocid1.subnet.oc1.eu-marseille-1.aaaaaaaapz6g4htlyisp45zplqi47t3mms4noceyqebb5huhccrlt432ugeq

echo ""
echo "=== Compute Instances (for_each key = terraform.json .instances[].key) ==="
terraform import 'oci_core_instance.vms["mail_server"]' \
  ocid1.instance.oc1.eu-marseille-1.anwxeljruadvczacbwylmkqr253ay7binepapgsyopllfayovkzaky6oigbq

terraform import 'oci_core_instance.vms["analytics_server"]' \
  ocid1.instance.oc1.eu-marseille-1.anwxeljruadvczacgwg5rkrjyomuxvjtvtuk5xrbmy7hmslwn4pse4kw5jkq

terraform import 'oci_core_instance.vms["apps_server"]' \
  ocid1.instance.oc1.eu-marseille-1.anwxeljruadvczacj7dfxl7uifar574je7fzlvtdjp4ghljdwuwdemsdbiva

echo ""
echo "=== Object Storage (for_each key = bucket name) ==="
terraform import 'oci_objectstorage_bucket.buckets["cloud-backups-binaries-medias"]' \
  "n/${NS}/b/cloud-backups-binaries-medias"

terraform import 'oci_objectstorage_bucket.buckets["cloud-backups-db"]' \
  "n/${NS}/b/cloud-backups-db"

terraform import 'oci_objectstorage_bucket.buckets["cloud-backups-media"]' \
  "n/${NS}/b/cloud-backups-media"

terraform import 'oci_objectstorage_bucket.buckets["cloud-backups-non-binaries"]' \
  "n/${NS}/b/cloud-backups-non-binaries"

terraform import 'oci_objectstorage_bucket.buckets["my-photos"]' \
  "n/${NS}/b/my-photos"

echo ""
echo "=== Email Senders (for_each key = email address) ==="
terraform import 'oci_email_sender.senders["me@diegonmarcos.com"]' \
  ocid1.emailsender.oc1.eu-marseille-1.amaaaaaauadvczaaumrpqz622tzkrekelr2qgsspgazxdfmbi4dtmknjay2q \
  2>/dev/null || echo "  me@ already imported"

terraform import 'oci_email_sender.senders["no-reply@diegonmarcos.com"]' \
  ocid1.emailsender.oc1.eu-marseille-1.amaaaaaauadvczaaorpuusj6j7pevcsugax4v47bou6u3drmobzrbzh7ktba \
  2>/dev/null || echo "  no-reply@ already imported"

echo ""
echo "=== Budget ==="
BUDGET_ID="ocid1.budget.oc1.eu-marseille-1.amaaaaaauadvczaahk3wenhiyffruiliejvkc5uvfgikdpoe7opikgitocta"
terraform import oci_budget_budget.main "$BUDGET_ID"

terraform import 'oci_budget_alert_rule.alerts["50pct-spend-alert"]' \
  "budgets/${BUDGET_ID}/alertRules/ocid1.alertrule.oc1.eu-marseille-1.amaaaaaauadvczaam6k7hbckup42jnfi6f4fx7ntqn27onmjrg63ujpd43ca"

terraform import 'oci_budget_alert_rule.alerts["90pct-spend-alert"]' \
  "budgets/${BUDGET_ID}/alertRules/ocid1.alertrule.oc1.eu-marseille-1.amaaaaaauadvczaag2fpnzkgnrxyg6gse4jhbw4dperqfpuzicgqfb5ss46q"

terraform import 'oci_budget_alert_rule.alerts["100pct-spend-alert"]' \
  "budgets/${BUDGET_ID}/alertRules/ocid1.alertrule.oc1.eu-marseille-1.amaaaaaauadvczaajyzmliqrvpuchjrnbaoi32c22bueaklesptsh7h2v7nq"

echo ""
echo "=== Done. Now run: terraform plan ==="
