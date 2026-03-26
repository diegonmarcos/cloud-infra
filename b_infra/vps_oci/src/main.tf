# OCI Infrastructure — data-driven from terraform.json
# All values live in terraform.json; this file is a pure template.

locals {
  config    = jsondecode(file("${path.module}/terraform.json"))
  net       = local.config.network
  proxy_src = "${local.config.gcp_proxy_ip}/32"

  # Resolve "gcp_proxy" source references to actual IP
  ingress_rules = [
    for r in local.config.security_rules.ingress : merge(r, {
      source = r.source == "gcp_proxy" ? local.proxy_src : r.source
    })
  ]

  # Separate TCP and UDP rules for correct options blocks
  tcp_rules = [for r in local.ingress_rules : r if r.protocol == "6"]
  udp_rules = [for r in local.ingress_rules : r if r.protocol == "17"]

  # Flex instances need shape_config
  flex_instances = { for i in local.config.instances : i.key => i if i.memory_in_gbs != null }
}

# =============================================================================
# Provider
# =============================================================================

terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 5.0"
    }
  }
}

provider "oci" {
  region = local.config.provider.region
}

variable "tenancy_ocid" {
  description = "OCI Tenancy OCID"
  type        = string
}

variable "compartment_ocid" {
  description = "OCI Compartment OCID"
  type        = string
}

# =============================================================================
# VCN (Virtual Cloud Network)
# =============================================================================

resource "oci_core_vcn" "main" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = [local.net.vcn_cidr]
  display_name   = local.net.vcn_name

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [defined_tags]
  }
}

resource "oci_core_internet_gateway" "main" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = local.net.igw_name
  enabled        = true

  lifecycle {
    ignore_changes = [defined_tags]
  }
}

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
# Security List — ingress rules driven by terraform.json
# =============================================================================

resource "oci_core_default_security_list" "main" {
  manage_default_resource_id = oci_core_vcn.main.default_security_list_id

  dynamic "egress_security_rules" {
    for_each = local.config.security_rules.egress
    content {
      destination = egress_security_rules.value.destination
      protocol    = egress_security_rules.value.protocol
      stateless   = egress_security_rules.value.stateless
    }
  }

  # TCP ingress rules
  dynamic "ingress_security_rules" {
    for_each = local.tcp_rules
    content {
      source      = ingress_security_rules.value.source
      protocol    = ingress_security_rules.value.protocol
      stateless   = false
      description = ingress_security_rules.value.description
      tcp_options {
        min = ingress_security_rules.value.port
        max = ingress_security_rules.value.port
      }
    }
  }

  # UDP ingress rules
  dynamic "ingress_security_rules" {
    for_each = local.udp_rules
    content {
      source      = ingress_security_rules.value.source
      protocol    = ingress_security_rules.value.protocol
      stateless   = false
      description = ingress_security_rules.value.description
      udp_options {
        min = ingress_security_rules.value.port
        max = ingress_security_rules.value.port
      }
    }
  }

  lifecycle {
    ignore_changes = [defined_tags]
  }
}

# =============================================================================
# Subnet
# =============================================================================

resource "oci_core_subnet" "main" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = local.net.subnet_cidr
  display_name               = local.net.subnet_name
  prohibit_public_ip_on_vnic = false
  prohibit_internet_ingress  = false

  route_table_id    = oci_core_vcn.main.default_route_table_id
  security_list_ids = [oci_core_vcn.main.default_security_list_id]
  dhcp_options_id   = oci_core_vcn.main.default_dhcp_options_id

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [defined_tags]
  }
}

# =============================================================================
# Compute Instances — all from terraform.json
# =============================================================================

resource "oci_core_instance" "vms" {
  for_each = { for i in local.config.instances : i.key => i }

  availability_domain = local.net.availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = each.value.display_name
  shape               = each.value.shape
  fault_domain        = each.value.fault_domain

  dynamic "shape_config" {
    for_each = each.value.memory_in_gbs != null ? [1] : []
    content {
      ocpus         = each.value.ocpus
      memory_in_gbs = each.value.memory_in_gbs
    }
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.main.id
    display_name     = each.value.vnic_display_name
    assign_public_ip = true
  }

  source_details {
    source_type             = "image"
    source_id               = each.value.image_id
    boot_volume_size_in_gbs = each.value.boot_volume_size_gb
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

resource "oci_objectstorage_bucket" "buckets" {
  for_each = { for b in local.config.buckets : b.name => b }

  compartment_id        = var.compartment_ocid
  namespace             = local.config.os_namespace
  name                  = each.value.name
  access_type           = each.value.access_type
  storage_tier          = each.value.storage_tier
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

resource "oci_email_sender" "senders" {
  for_each = toset(local.config.email_senders)

  compartment_id = var.compartment_ocid
  email_address  = each.value

  lifecycle {
    ignore_changes = [defined_tags]
  }
}

# =============================================================================
# Budget Alerts
# =============================================================================

resource "oci_budget_budget" "main" {
  compartment_id = var.tenancy_ocid
  amount         = local.config.budget.amount
  reset_period   = local.config.budget.reset_period
  display_name   = local.config.budget.display_name
  description    = local.config.budget.description
  target_type    = "COMPARTMENT"
  targets        = [var.tenancy_ocid]

  lifecycle {
    ignore_changes = [defined_tags]
  }
}

resource "oci_budget_alert_rule" "alerts" {
  for_each = { for a in local.config.budget.alert_thresholds : a.name => a }

  budget_id      = oci_budget_budget.main.id
  display_name   = each.value.name
  type           = "ACTUAL"
  threshold      = each.value.threshold
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
    for key, vm in oci_core_instance.vms : local.config.instances[index(local.config.instances.*.key, key)].display_name => {
      id    = vm.id
      shape = vm.shape
      ip    = local.config.instances[index(local.config.instances.*.key, key)].ip
    }
  }
}

output "buckets" {
  value = { for name, b in oci_objectstorage_bucket.buckets : name => b.name }
}
