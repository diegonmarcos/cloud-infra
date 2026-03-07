#!/bin/sh
# Import existing OCI resources into Terraform state.
# Run AFTER: cd terraform && terraform init
# Safe: import only reads, never modifies infrastructure.
# After: terraform plan → should show 0 changes.
set -eu

cd "$(dirname "$0")/../terraform"

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
echo "=== Compute Instances ==="
terraform import oci_core_instance.mail_server \
  ocid1.instance.oc1.eu-marseille-1.anwxeljruadvczacbwylmkqr253ay7binepapgsyopllfayovkzaky6oigbq

terraform import oci_core_instance.analytics_server \
  ocid1.instance.oc1.eu-marseille-1.anwxeljruadvczacgwg5rkrjyomuxvjtvtuk5xrbmy7hmslwn4pse4kw5jkq

terraform import oci_core_instance.apps_server \
  ocid1.instance.oc1.eu-marseille-1.anwxeljruadvczacj7dfxl7uifar574je7fzlvtdjp4ghljdwuwdemsdbiva

echo ""
echo "=== Object Storage ==="
terraform import oci_objectstorage_bucket.archlinux_images \
  n/axpmn3qtq4ig/b/archlinux-images

terraform import oci_objectstorage_bucket.my_photos \
  n/axpmn3qtq4ig/b/my-photos

echo ""
echo "=== Email Senders (already in state — skip if exists) ==="
terraform import oci_email_sender.me \
  ocid1.emailsender.oc1.eu-marseille-1.amaaaaaauadvczaaumrpqz622tzkrekelr2qgsspgazxdfmbi4dtmknjay2q \
  2>/dev/null || echo "  me@ already imported"

terraform import oci_email_sender.no_reply \
  ocid1.emailsender.oc1.eu-marseille-1.amaaaaaauadvczaaorpuusj6j7pevcsugax4v47bou6u3drmobzrbzh7ktba \
  2>/dev/null || echo "  no-reply@ already imported"

echo ""
echo "=== Budget ==="
terraform import oci_budget_budget.tenancy_budget \
  ocid1.budget.oc1.eu-marseille-1.amaaaaaauadvczaaufmg3asko2jw26tfsu4gbwfrws6msrt2x7rkuqq7revq

terraform import oci_budget_alert_rule.half_budget \
  ocid1.alertrule.oc1.eu-marseille-1.amaaaaaauadvczaahcbpvrzfxj37f7b2jmvw7jwvqszarbgx4zchlwe42oha

terraform import oci_budget_alert_rule.ninety_budget \
  ocid1.alertrule.oc1.eu-marseille-1.amaaaaaauadvczaav3iact36c6swsun5pcqv2ydz3bjxxhy7yrracyykfbwq

terraform import oci_budget_alert_rule.full_budget \
  ocid1.alertrule.oc1.eu-marseille-1.amaaaaaauadvczaacd3satuf3nupzcqabzrxkskyyysykpeyens5u6ztqdna

echo ""
echo "=== Done. Now run: terraform plan ==="
