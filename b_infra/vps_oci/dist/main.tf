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
  # Auth via ~/.oci/config or environment variables
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

# =============================================================================
# VCN (Virtual Cloud Network)
# =============================================================================

resource "oci_core_vcn" "main" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = ["10.0.0.0/16"]
  display_name   = "main-vcn"
  dns_label      = "mainvcn"
}

resource "oci_core_internet_gateway" "main" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "main-igw"
  enabled        = true
}

resource "oci_core_route_table" "main" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "main-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main.id
  }
}

# =============================================================================
# Security List - Mail Server (oci-E2-f_0 / oci-mail)
# =============================================================================

resource "oci_core_security_list" "mail_server" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "mail-server-security-list"

  # Egress - Allow all outbound
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
    stateless   = false
  }

  # SSH
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "6"  # TCP
    stateless = false
    tcp_options {
      min = 22
      max = 22
    }
  }

  # SMTP (25)
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "6"
    stateless = false
    tcp_options {
      min = 25
      max = 25
    }
  }

  # SMTP Implicit TLS (465)
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "6"
    stateless = false
    tcp_options {
      min = 465
      max = 465
    }
  }

  # SMTP Submission (587)
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "6"
    stateless = false
    tcp_options {
      min = 587
      max = 587
    }
  }

  # IMAPS (993)
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "6"
    stateless = false
    tcp_options {
      min = 993
      max = 993
    }
  }

  # HTTPS (443) - from GCP proxy
  ingress_security_rules {
    source    = "${var.gcp_proxy_ip}/32"
    protocol  = "6"
    stateless = false
    tcp_options {
      min = 443
      max = 443
    }
  }

  # HTTP (8080) - SMTP proxy for Cloudflare Worker email delivery
  # Cloudflare Workers use Cloudflare IPs (not GCP), must allow 0.0.0.0/0
  # Protected by API key (X-API-Key: stalwart-proxy-key-2025)
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "6"
    stateless = false
    tcp_options {
      min = 8080
      max = 8080
    }
  }

  # WireGuard (51820)
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "17"  # UDP
    stateless = false
    udp_options {
      min = 51820
      max = 51820
    }
  }

  # ICMP
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "1"
    stateless = false
    icmp_options {
      type = 3
      code = 4
    }
  }

  ingress_security_rules {
    source    = "10.0.0.0/16"
    protocol  = "1"
    stateless = false
    icmp_options {
      type = 3
    }
  }
}

# =============================================================================
# Security List - Analytics Server (oci-E2-f_1 / oci-analytics)
# =============================================================================

resource "oci_core_security_list" "analytics_server" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "analytics-server-security-list"

  # Egress - Allow all outbound
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
    stateless   = false
  }

  # SSH
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "6"
    stateless = false
    tcp_options {
      min = 22
      max = 22
    }
  }

  # HTTP (80) - from GCP proxy
  ingress_security_rules {
    source    = "${var.gcp_proxy_ip}/32"
    protocol  = "6"
    stateless = false
    tcp_options {
      min = 80
      max = 80
    }
  }

  # HTTPS (443) - from GCP proxy
  ingress_security_rules {
    source    = "${var.gcp_proxy_ip}/32"
    protocol  = "6"
    stateless = false
    tcp_options {
      min = 443
      max = 443
    }
  }

  # Matomo (8080) - from GCP proxy
  ingress_security_rules {
    source    = "${var.gcp_proxy_ip}/32"
    protocol  = "6"
    stateless = false
    tcp_options {
      min = 8080
      max = 8080
    }
  }

  # WireGuard (51820)
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "17"
    stateless = false
    udp_options {
      min = 51820
      max = 51820
    }
  }

  # ICMP
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "1"
    stateless = false
    icmp_options {
      type = 3
      code = 4
    }
  }
}

# =============================================================================
# Security List - Apps Server (oci-A1-f_0 / oci-apps)
# Consolidated: all services from former oci-apps + oci-apps-1
# =============================================================================

resource "oci_core_security_list" "apps_server" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "apps-server-security-list"

  # Egress - Allow all outbound
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
    stateless   = false
  }

  # SSH
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "6"
    stateless = false
    tcp_options {
      min = 22
      max = 22
    }
  }

  # Rust API (8080) - from GCP proxy
  ingress_security_rules {
    source    = "${var.gcp_proxy_ip}/32"
    protocol  = "6"
    stateless = false
    tcp_options {
      min = 8080
      max = 8080
    }
  }

  # HTTPS (443) - from GCP proxy (migrated from oci-apps-1)
  ingress_security_rules {
    source    = "${var.gcp_proxy_ip}/32"
    protocol  = "6"
    stateless = false
    tcp_options {
      min = 443
      max = 443
    }
  }

  # PhotoPrism (2342) - from GCP proxy (migrated from oci-apps-1)
  ingress_security_rules {
    source    = "${var.gcp_proxy_ip}/32"
    protocol  = "6"
    stateless = false
    tcp_options {
      min = 2342
      max = 2342
    }
  }

  # Radicale (5232) - from GCP proxy (migrated from oci-apps-1)
  ingress_security_rules {
    source    = "${var.gcp_proxy_ip}/32"
    protocol  = "6"
    stateless = false
    tcp_options {
      min = 5232
      max = 5232
    }
  }

  # Code Server (8443) - from GCP proxy (migrated from oci-apps-1)
  ingress_security_rules {
    source    = "${var.gcp_proxy_ip}/32"
    protocol  = "6"
    stateless = false
    tcp_options {
      min = 8443
      max = 8443
    }
  }

  # NocoDB (8085) - from GCP proxy (migrated from oci-apps-1)
  ingress_security_rules {
    source    = "${var.gcp_proxy_ip}/32"
    protocol  = "6"
    stateless = false
    tcp_options {
      min = 8085
      max = 8085
    }
  }

  # AFFiNE (3010) - from GCP proxy (migrated from oci-apps-1)
  ingress_security_rules {
    source    = "${var.gcp_proxy_ip}/32"
    protocol  = "6"
    stateless = false
    tcp_options {
      min = 3010
      max = 3010
    }
  }

  # Syncthing (22000) - direct access (migrated from oci-apps-1)
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "6"
    stateless = false
    tcp_options {
      min = 22000
      max = 22000
    }
  }

  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "17"  # UDP
    stateless = false
    udp_options {
      min = 22000
      max = 22000
    }
  }

  # Syncthing Discovery (21027) - migrated from oci-apps-1
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "17"
    stateless = false
    udp_options {
      min = 21027
      max = 21027
    }
  }

  # WireGuard (51820)
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "17"
    stateless = false
    udp_options {
      min = 51820
      max = 51820
    }
  }

  # ICMP
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "1"
    stateless = false
    icmp_options {
      type = 3
      code = 4
    }
  }
}

# =============================================================================
# Security List - Dev Server (oci-A1-f_1 / oci-apps-1) — DECOMMISSIONED
# Rules merged into apps_server. Kept for terraform state until instance deleted.
# =============================================================================

resource "oci_core_security_list" "dev_server" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "dev-server-security-list-DECOMMISSIONED"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
    stateless   = false
  }

  # Minimal: SSH only (for decommission access)
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "6"
    stateless = false
    tcp_options {
      min = 22
      max = 22
    }
  }

  # ICMP
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "1"
    stateless = false
    icmp_options {
      type = 3
      code = 4
    }
  }
}

# =============================================================================
# Security List - Flex Server 2 (oci-A1-p_0 / oci-apps-2)
# =============================================================================

resource "oci_core_security_list" "flex2_server" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "flex2-server-security-list"

  # Egress - Allow all outbound
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
    stateless   = false
  }

  # SSH
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "6"
    stateless = false
    tcp_options {
      min = 22
      max = 22
    }
  }

  # WireGuard (51820)
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "17"
    stateless = false
    udp_options {
      min = 51820
      max = 51820
    }
  }

  # ICMP
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "1"
    stateless = false
    icmp_options {
      type = 3
      code = 4
    }
  }
}

# =============================================================================
# OCI Email Delivery - Approved Senders
# These addresses are authorized to send via OCI SMTP relay
# (smtp.email.eu-marseille-1.oci.oraclecloud.com:587)
# =============================================================================

resource "oci_email_sender" "me" {
  compartment_id = var.compartment_ocid
  email_address  = "me@diegonmarcos.com"
}

resource "oci_email_sender" "no_reply" {
  compartment_id = var.compartment_ocid
  email_address  = "no-reply@diegonmarcos.com"
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

  targets = [var.tenancy_ocid]
}

resource "oci_budget_alert_rule" "half_budget" {
  budget_id    = oci_budget_budget.tenancy_budget.id
  display_name = "50pct-spend-alert"
  type         = "ACTUAL"
  threshold      = 50
  threshold_type = "PERCENTAGE"
}

resource "oci_budget_alert_rule" "ninety_budget" {
  budget_id    = oci_budget_budget.tenancy_budget.id
  display_name = "90pct-spend-alert"
  type         = "ACTUAL"
  threshold      = 90
  threshold_type = "PERCENTAGE"
}

resource "oci_budget_alert_rule" "full_budget" {
  budget_id    = oci_budget_budget.tenancy_budget.id
  display_name = "100pct-spend-alert"
  type         = "ACTUAL"
  threshold      = 100
  threshold_type = "PERCENTAGE"
}

# =============================================================================
# IAM Policies
# =============================================================================

resource "oci_identity_policy" "boot_volume_management" {
  compartment_id = var.tenancy_ocid
  name           = "boot-volume-management-policy"
  description    = "Allow management of boot volumes for CLI operations"

  statements = [
    "Allow any-user to manage boot-volumes in tenancy",
    "Allow any-user to manage volume-attachments in tenancy",
    "Allow any-user to read boot-volume-attachments in tenancy"
  ]
}

# =============================================================================
# Outputs
# =============================================================================

output "vcn_id" {
  value       = oci_core_vcn.main.id
  description = "VCN OCID"
}

output "security_lists" {
  value = {
    mail_server      = oci_core_security_list.mail_server.id
    analytics_server = oci_core_security_list.analytics_server.id
    apps_server      = oci_core_security_list.apps_server.id
    dev_server       = oci_core_security_list.dev_server.id  # DECOMMISSIONED — kept for state
    flex2_server     = oci_core_security_list.flex2_server.id
  }
  description = "Security List OCIDs"
}

output "instance_info" {
  value = {
    "oci-E2-f_0" = {
      ip   = "130.110.251.193"
      ocid = "ocid1.instance.oc1.eu-marseille-1.anwxeljruadvczacbwylmkqr253ay7binepapgsyopllfayovkzaky6oigbq"
      role = "Mail Server (oci-mail)"
    }
    "oci-E2-f_1" = {
      ip   = "129.151.228.66"
      ocid = "ocid1.instance.oc1.eu-marseille-1.anwxeljruadvczacgwg5rkrjyomuxvjtvtuk5xrbmy7hmslwn4pse4kw5jkq"
      role = "Analytics (oci-analytics)"
    }
    "oci-A1-f_0" = {
      ip   = "82.70.229.129"
      ocid = "ocid1.instance.oc1.eu-marseille-1.anwxeljruadvczacj7dfxl7uifar574je7fzlvtdjp4ghljdwuwdemsdbiva"
      role = "Consolidated Apps Server (oci-apps) — 4 OCPUs / 24GB / 100GB"
    }
    # oci-A1-f_1 DECOMMISSIONED — all services migrated to oci-A1-f_0
    "oci-A1-p_0" = {
      ip   = "79.72.28.10"
      ocid = "FILL_FROM_OCI_CONSOLE"
      role = "Flex Server 2 (oci-apps-2)"
    }
  }
  description = "Instance information"
}
