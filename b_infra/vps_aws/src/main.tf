# AWS SES — SMTP relay for Mailu outbound email
# Domain: diegonmarcos.com | Region: us-east-1
# Outputs SMTP credentials + DNS verification tokens for Cloudflare

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  default = "us-east-1"
}

variable "domain" {
  default = "diegonmarcos.com"
}

# =============================================================================
# SES Domain Identity + Verification
# =============================================================================

resource "aws_ses_domain_identity" "main" {
  domain = var.domain
}

# Easy DKIM — SES generates 3 CNAME records
resource "aws_ses_domain_dkim" "main" {
  domain = aws_ses_domain_identity.main.domain
}

# Custom MAIL FROM (bounce subdomain)
resource "aws_ses_domain_mail_from" "main" {
  domain           = aws_ses_domain_identity.main.domain
  mail_from_domain = "mail.${var.domain}"
}

# =============================================================================
# IAM User — dedicated SMTP credentials
# =============================================================================

resource "aws_iam_user" "ses_smtp" {
  name = "ses-smtp-mailu"
}

resource "aws_iam_user_policy" "ses_smtp" {
  name = "ses-send-email"
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
  description = "TXT record value for _amazonses.diegonmarcos.com"
  value       = aws_ses_domain_identity.main.verification_token
}

output "ses_dkim_tokens" {
  description = "3 DKIM CNAME tokens: <token>._domainkey → <token>.dkim.amazonses.com"
  value       = aws_ses_domain_dkim.main.dkim_tokens
}

output "smtp_endpoint" {
  description = "SES SMTP endpoint"
  value       = "email-smtp.${var.region}.amazonaws.com"
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
  value       = "feedback-smtp.${var.region}.amazonses.com"
}

output "mail_from_spf" {
  description = "SPF TXT record for custom MAIL FROM subdomain"
  value       = "v=spf1 include:amazonses.com ~all"
}
