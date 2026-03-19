terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 5.0"
    }
  }
}

provider "oci" {
  region = var.region
}

variable "region" {
  description = "OCI Region"
  type        = string
  default     = "eu-marseille-1"
}

variable "tenancy_ocid" {
  description = "OCI Tenancy OCID"
  type        = string
}

variable "compartment_ocid" {
  description = "OCI Compartment OCID"
  type        = string
}

variable "gcp_proxy_ip" {
  description = "GCP Central Proxy IP for whitelisting"
  type        = string
  default     = "35.226.147.64"
}

variable "os_namespace" {
  description = "OCI Object Storage namespace"
  type        = string
  default     = "axpmn3qtq4ig"
}

# =============================================================================
# VCN (Virtual Cloud Network)
# =============================================================================

resource "oci_core_vcn" "main" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = ["10.0.0.0/16"]
  display_name   = "web-server-vcn"
  # dns_label not set (null in OCI)

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [defined_tags]
  }
}

resource "oci_core_internet_gateway" "main" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "web-server-igw"
  enabled        = true

  lifecycle {
    ignore_changes = [defined_tags]
  }
}

# Default Route Table (auto-created with VCN)
resource "oci_core_default_route_table" "main" {
  manage_default_resource_id = oci_core_vcn.main.default_route_table_id

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main.id
  }

  lifecycle {
    ignore_changes = [defined_tags]
  }
}

# =============================================================================
# Default Security List (shared by all VMs via single subnet)
# Exact rule order as returned by OCI API
# =============================================================================

resource "oci_core_default_security_list" "main" {
  manage_default_resource_id = oci_core_vcn.main.default_security_list_id

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
    stateless   = false
  }

  # 1. SSH (22)
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "6"
    stateless = false
    tcp_options {
      min = 22
      max = 22
    }
  }

  # 1b. Rescue SSH — Dropbear (2200)
  ingress_security_rules {
    source      = "0.0.0.0/0"
    protocol    = "6"
    stateless   = false
    description = "Rescue SSH (Dropbear) — untouchable OOM-immune supervisor"
    tcp_options {
      min = 2200
      max = 2200
    }
  }

  # 2. SMTP (25) — REMOVED: inbound via CF Tunnel, not public port
  # 3. HTTP (80)
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "6"
    stateless = false
    tcp_options {
      min = 80
      max = 80
    }
  }

  # 4. HTTPS (443)
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "6"
    stateless = false
    tcp_options {
      min = 443
      max = 443
    }
  }

  # 5. HTTP alt (8080)
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "6"
    stateless = false
    tcp_options {
      min = 8080
      max = 8080
    }
  }

  # 6. Matomo Analytics (8081)
  ingress_security_rules {
    source      = "0.0.0.0/0"
    protocol    = "6"
    stateless   = false
    description = "Matomo Analytics"
    tcp_options {
      min = 8081
      max = 8081
    }
  }

  # 7. HTTP alt (81)
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "6"
    stateless = false
    tcp_options {
      min = 81
      max = 81
    }
  }

  # 8. n8n (5678)
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "6"
    stateless = false
    tcp_options {
      min = 5678
      max = 5678
    }
  }

  # 9. Syncthing (8384)
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "6"
    stateless = false
    tcp_options {
      min = 8384
      max = 8384
    }
  }

  # 10. Syncthing TCP (22000)
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "6"
    stateless = false
    tcp_options {
      min = 22000
      max = 22000
    }
  }

  # 11. Flask API (5000)
  ingress_security_rules {
    source      = "0.0.0.0/0"
    protocol    = "6"
    stateless   = false
    description = "Flask API"
    tcp_options {
      min = 5000
      max = 5000
    }
  }

  # 12. Snappymail Webmail (8888)
  ingress_security_rules {
    source      = "0.0.0.0/0"
    protocol    = "6"
    stateless   = false
    description = "Snappymail Webmail"
    tcp_options {
      min = 8888
      max = 8888
    }
  }

  # 13-15. SMTP/IMAPS/SMTPS (587, 993, 465) — REMOVED: mail access via WG only (Caddy L4 on gcp-proxy)

  # 16. SMTP Proxy for Cloudflare Worker (8088)
  ingress_security_rules {
    source      = "0.0.0.0/0"
    protocol    = "6"
    stateless   = false
    description = "SMTP Proxy for Cloudflare Worker"
    tcp_options {
      min = 8088
      max = 8088
    }
  }

  # 17. WireGuard VPN (51820/UDP)
  ingress_security_rules {
    source      = "0.0.0.0/0"
    protocol    = "17"
    stateless   = false
    description = "WireGuard VPN"
    udp_options {
      min = 51820
      max = 51820
    }
  }

  # 18. Radicale (5232) — from GCP proxy
  ingress_security_rules {
    source    = "${var.gcp_proxy_ip}/32"
    protocol  = "6"
    stateless = false
    tcp_options {
      min = 5232
      max = 5232
    }
  }

  # 19. AFFiNE (3010) — from GCP proxy
  ingress_security_rules {
    source      = "${var.gcp_proxy_ip}/32"
    protocol    = "6"
    stateless   = false
    description = "AFFiNE from NPM"
    tcp_options {
      min = 3010
      max = 3010
    }
  }

  # 20. Code Server (8443) — from GCP proxy
  ingress_security_rules {
    source      = "${var.gcp_proxy_ip}/32"
    protocol    = "6"
    stateless   = false
    description = "Code-Server from NPM"
    tcp_options {
      min = 8443
      max = 8443
    }
  }

  # 21. NocoDB (8085) — from GCP proxy
  ingress_security_rules {
    source      = "${var.gcp_proxy_ip}/32"
    protocol    = "6"
    stateless   = false
    description = "NocoDB from NPM"
    tcp_options {
      min = 8085
      max = 8085
    }
  }

  lifecycle {
    ignore_changes = [defined_tags]
  }
}

# =============================================================================
# Subnet (shared by all VMs)
# =============================================================================

resource "oci_core_subnet" "main" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = "10.0.1.0/24"
  display_name               = "web-server-subnet"
  prohibit_public_ip_on_vnic = false
  prohibit_internet_ingress  = false
  # dns_label not set (null in OCI)

  route_table_id    = oci_core_vcn.main.default_route_table_id
  security_list_ids = [oci_core_vcn.main.default_security_list_id]
  dhcp_options_id   = oci_core_vcn.main.default_dhcp_options_id

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [defined_tags]
  }
}

# =============================================================================
# Compute Instances
# =============================================================================

# oci-E2-f_0 / oci-mail — Mail Server
# Shape: VM.Standard.E2.1.Micro | 1 OCPU | 1 GB RAM | 47 GB boot
resource "oci_core_instance" "mail_server" {
  availability_domain = "bRpM:EU-MARSEILLE-1-AD-1"
  compartment_id      = var.compartment_ocid
  display_name        = "oci-E2-f_0"
  shape               = "VM.Standard.E2.1.Micro"
  fault_domain        = "FAULT-DOMAIN-2"

  create_vnic_details {
    subnet_id        = oci_core_subnet.main.id
    display_name     = "web-server"
    assign_public_ip = true
  }

  source_details {
    source_type             = "image"
    source_id               = "ocid1.image.oc1.eu-marseille-1.aaaaaaaaroyr7dd2stfnhbjmqrqrbvhoa77i6o3eap6er6cd5rxjzxgu73oq"
    boot_volume_size_in_gbs = 47
  }

  metadata = {}

  agent_config {
    are_all_plugins_disabled = false
    is_management_disabled   = false
    is_monitoring_disabled   = false
  }

  instance_options {
    are_legacy_imds_endpoints_disabled = false
  }

  availability_config {
    recovery_action = "RESTORE_INSTANCE"
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [source_details, metadata, create_vnic_details, defined_tags, freeform_tags]
  }
}

# oci-E2-f_1 / oci-analytics — Analytics + Workflows
# Shape: VM.Standard.E2.1.Micro | 1 OCPU | 1 GB RAM | 50 GB boot
resource "oci_core_instance" "analytics_server" {
  availability_domain = "bRpM:EU-MARSEILLE-1-AD-1"
  compartment_id      = var.compartment_ocid
  display_name        = "oci-E2-f_1"
  shape               = "VM.Standard.E2.1.Micro"
  fault_domain        = "FAULT-DOMAIN-1"

  create_vnic_details {
    subnet_id        = oci_core_subnet.main.id
    display_name     = "services-server"
    assign_public_ip = true
  }

  source_details {
    source_type             = "image"
    source_id               = "ocid1.image.oc1.eu-marseille-1.aaaaaaaaroyr7dd2stfnhbjmqrqrbvhoa77i6o3eap6er6cd5rxjzxgu73oq"
    boot_volume_size_in_gbs = 50
  }

  metadata = {}

  agent_config {
    are_all_plugins_disabled = false
    is_management_disabled   = false
    is_monitoring_disabled   = false
  }

  instance_options {
    are_legacy_imds_endpoints_disabled = false
  }

  availability_config {
    recovery_action = "RESTORE_INSTANCE"
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [source_details, metadata, create_vnic_details, defined_tags, freeform_tags]
  }
}

# oci-A1-f_0 / oci-apps — Consolidated Apps Server
# Shape: VM.Standard.A1.Flex | 4 OCPUs | 24 GB RAM | 100 GB boot
resource "oci_core_instance" "apps_server" {
  availability_domain = "bRpM:EU-MARSEILLE-1-AD-1"
  compartment_id      = var.compartment_ocid
  display_name        = "oci-A1-f_0"
  shape               = "VM.Standard.A1.Flex"
  fault_domain        = "FAULT-DOMAIN-2"

  shape_config {
    ocpus         = 4
    memory_in_gbs = 24
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.main.id
    display_name     = "arm-server-1"
    assign_public_ip = true
  }

  source_details {
    source_type             = "image"
    source_id               = "ocid1.image.oc1.eu-marseille-1.aaaaaaaar3pm2xlih5tqkjwr7ykfgzixjytjivkacgmqrlxi66vzlf5a2wlq"
    boot_volume_size_in_gbs = 100
  }

  metadata = {}

  agent_config {
    are_all_plugins_disabled = false
    is_management_disabled   = false
    is_monitoring_disabled   = false
  }

  instance_options {
    are_legacy_imds_endpoints_disabled = false
  }

  availability_config {
    recovery_action = "RESTORE_INSTANCE"
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [source_details, metadata, create_vnic_details, defined_tags, freeform_tags]
  }
}

# =============================================================================
# Object Storage
# =============================================================================

resource "oci_objectstorage_bucket" "archlinux_images" {
  compartment_id        = var.compartment_ocid
  namespace             = var.os_namespace
  name                  = "archlinux-images"
  access_type           = "NoPublicAccess"
  storage_tier          = "Standard"
  versioning            = "Disabled"
  object_events_enabled = false

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [defined_tags]
  }
}

resource "oci_objectstorage_bucket" "my_photos" {
  compartment_id        = var.compartment_ocid
  namespace             = var.os_namespace
  name                  = "my-photos"
  access_type           = "NoPublicAccess"
  storage_tier          = "Standard"
  versioning            = "Disabled"
  object_events_enabled = false

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [defined_tags]
  }
}

# =============================================================================
# OCI Email Delivery
# =============================================================================

resource "oci_email_sender" "me" {
  compartment_id = var.compartment_ocid
  email_address  = "me@diegonmarcos.com"

  lifecycle {
    ignore_changes = [defined_tags]
  }
}

resource "oci_email_sender" "no_reply" {
  compartment_id = var.compartment_ocid
  email_address  = "no-reply@diegonmarcos.com"

  lifecycle {
    ignore_changes = [defined_tags]
  }
}

# =============================================================================
# Budget Alerts
# =============================================================================

resource "oci_budget_budget" "tenancy_budget" {
  compartment_id = var.tenancy_ocid
  amount         = 30
  reset_period   = "MONTHLY"
  display_name   = "OCI-Free-Tier-30EUR"
  description    = "Alert if OCI spend exceeds free tier expectations"
  target_type    = "COMPARTMENT"
  targets        = [var.tenancy_ocid]

  lifecycle {
    ignore_changes = [defined_tags]
  }
}

resource "oci_budget_alert_rule" "half_budget" {
  budget_id      = oci_budget_budget.tenancy_budget.id
  display_name   = "50pct-spend-alert"
  type           = "ACTUAL"
  threshold      = 50
  threshold_type = "PERCENTAGE"

  lifecycle {
    ignore_changes = [defined_tags]
  }
}

resource "oci_budget_alert_rule" "ninety_budget" {
  budget_id      = oci_budget_budget.tenancy_budget.id
  display_name   = "90pct-spend-alert"
  type           = "ACTUAL"
  threshold      = 90
  threshold_type = "PERCENTAGE"

  lifecycle {
    ignore_changes = [defined_tags]
  }
}

resource "oci_budget_alert_rule" "full_budget" {
  budget_id      = oci_budget_budget.tenancy_budget.id
  display_name   = "100pct-spend-alert"
  type           = "ACTUAL"
  threshold      = 100
  threshold_type = "PERCENTAGE"

  lifecycle {
    ignore_changes = [defined_tags]
  }
}

# =============================================================================
# Outputs
# =============================================================================

output "vcn_id" {
  value = oci_core_vcn.main.id
}

output "subnet_id" {
  value = oci_core_subnet.main.id
}

output "instances" {
  value = {
    "oci-E2-f_0" = {
      id    = oci_core_instance.mail_server.id
      shape = "VM.Standard.E2.1.Micro"
      ocpus = 1
      ram   = 1
      disk  = 47
      ip    = "130.110.251.193"
    }
    "oci-E2-f_1" = {
      id    = oci_core_instance.analytics_server.id
      shape = "VM.Standard.E2.1.Micro"
      ocpus = 1
      ram   = 1
      disk  = 50
      ip    = "129.151.228.66"
    }
    "oci-A1-f_0" = {
      id    = oci_core_instance.apps_server.id
      shape = "VM.Standard.A1.Flex"
      ocpus = 4
      ram   = 24
      disk  = 100
      ip    = "82.70.229.129"
    }
  }
}

output "buckets" {
  value = {
    "archlinux-images" = oci_objectstorage_bucket.archlinux_images.name
    "my-photos"        = oci_objectstorage_bucket.my_photos.name
  }
}
