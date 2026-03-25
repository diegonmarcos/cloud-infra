# AWS SES — data-driven from terraform.json
# SMTP relay for Mailu outbound email
# Outputs SMTP credentials + DNS verification tokens for Cloudflare

locals {
  config = jsondecode(file("${path.module}/terraform.json"))
}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = local.config.provider.version
    }
  }
}

provider "aws" {
  region = local.config.provider.region
}

# =============================================================================
# SES Domain Identity + Verification
# =============================================================================

resource "aws_ses_domain_identity" "main" {
  domain = local.config.domain
}

resource "aws_ses_domain_dkim" "main" {
  domain = aws_ses_domain_identity.main.domain
}

resource "aws_ses_domain_mail_from" "main" {
  domain           = aws_ses_domain_identity.main.domain
  mail_from_domain = "${local.config.mail_from_subdomain}.${local.config.domain}"
}

# =============================================================================
# IAM User — dedicated SMTP credentials
# =============================================================================

resource "aws_iam_user" "ses_smtp" {
  name = local.config.iam_user.name
}

resource "aws_iam_user_policy" "ses_smtp" {
  name = local.config.iam_user.policy_name
  user = aws_iam_user.ses_smtp.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ses:SendRawEmail"
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_access_key" "ses_smtp" {
  user = aws_iam_user.ses_smtp.name
}

# =============================================================================
# Outputs
# =============================================================================

output "ses_verification_token" {
  description = "TXT record value for _amazonses.${local.config.domain}"
  value       = aws_ses_domain_identity.main.verification_token
}

output "ses_dkim_tokens" {
  description = "3 DKIM CNAME tokens"
  value       = aws_ses_domain_dkim.main.dkim_tokens
}

output "smtp_endpoint" {
  description = "SES SMTP endpoint"
  value       = "email-smtp.${local.config.provider.region}.amazonaws.com"
}

output "smtp_username" {
  description = "SMTP username (IAM access key)"
  value       = aws_iam_access_key.ses_smtp.id
}

output "smtp_password" {
  description = "SMTP password (SES-derived secret)"
  value       = aws_iam_access_key.ses_smtp.ses_smtp_password_v4
  sensitive   = true
}

output "mail_from_mx" {
  description = "MX record for custom MAIL FROM subdomain"
  value       = "feedback-smtp.${local.config.provider.region}.amazonses.com"
}

output "mail_from_spf" {
  description = "SPF TXT record for custom MAIL FROM subdomain"
  value       = "v=spf1 include:amazonses.com ~all"
}
