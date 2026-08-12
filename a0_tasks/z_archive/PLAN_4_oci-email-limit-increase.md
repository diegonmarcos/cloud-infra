# OCI Email Delivery - Limit Increase Request

**Requested Region:**
> eu-marseille-1

**What is your current sending domain(s)?**
> diegonmarcos.com

**Have you set up SPF in your DNS for all your sending domains and regions?**
> Yes. SPF record: `v=spf1 include:_spf.mx.cloudflare.net include:eu.rp.oracleemaildelivery.com a:smtp.diegonmarcos.com ~all`

**Have you set up DKIM in your DNS for all your sending domains and regions?**
> Yes. DKIM is configured with selector `dkim._domainkey.diegonmarcos.com` (Mailu rspamd signs all outbound mail). Additional DKIM selectors are also present (Cloudflare Email Routing, legacy).

**Do your sending practices meet the requirements of CAN-SPAM and CASL?**
> Yes. All emails are sent to known recipients who have a pre-existing relationship. No bulk/unsolicited emails are sent. Every email includes valid sender identification.

**Please briefly describe the type of email you will be sending?**
> Personal and transactional emails only. This is a self-hosted personal email server (Mailu) for one user. Emails include personal correspondence, account notifications, calendar invites, and file sharing with attachments (documents, photos). No marketing, bulk, or newsletter emails.

**Do you send emails related to payday loans and/or credit card offers?**
> No

**Do you send mail on behalf of other companies?**
> No

**How do the recipients sign-up to receive these emails? Please specify any domains they may sign-up on.**
> N/A. This is a personal email account, not a mailing list. Recipients are personal and professional contacts who I email directly.

**Are there any other methods that are used to collect email addresses?**
> No. This is a single-user personal email server. No email addresses are collected.

**How many emails will you send per day on average? What is the maximum amount of emails you may send in a day?**
> Average: 5-10 emails per day. Maximum: 30 emails per day.

**Which service provider are you currently using to send your emails?**
> OCI Email Delivery (eu-marseille-1) as the SMTP relay for Mailu (self-hosted, running on OCI instance oci-mail / 130.110.251.193).

**What is the maximum amount of email you need to send in a minute?**
> 5 emails per minute.

**What is the average size of your email?**
> 50 KB (plain text / small HTML emails).

**What is the maximum size of your email?**
> 60 MB (emails with large photo or document attachments — this is the reason for the limit increase request, currently hitting the 2 MB cap).
