# Mailu Direct SMTP Delivery with OCI Relay Fallback

## Context

Mailu currently routes ALL outbound email through OCI Email Delivery relay (`smtp.email.eu-marseille-1.oci.oraclecloud.com:587`). OCI has a 2 MB message size limit (default), causing `552 exceeds byte limit` bounces for emails with attachments.

## Prerequisite: OCI Console Requests (manual, before any code changes)

### Request 1: Increase max-message-size to 60 MB (immediate fix)
- OCI Console → Governance → Limits, Quotas and Usage
- Service: `email-delivery`, Scope: `eu-marseille-1`
- Limit: `max-message-size`, Current: `2008192`, Request: `62914560`
- Direct URL: `https://cloud.oracle.com/limits?service=email-delivery&region=eu-marseille-1`

### Request 2: Unblock outbound port 25 (for direct delivery)
- OCI Console → Networking → Virtual Cloud Networks → Security Lists
- Or via Oracle Support: request SMTP port 25 outbound unblock for oci-mail (130.110.251.193)
- **Verified blocked**: `nc -w3 gmail-smtp-in.l.google.com 25` times out from oci-mail
- **Port 587 works**: OCI relay responds on 587

Once Request 1 is approved: bounce issue is fixed immediately (no code changes).
Once Request 2 is approved: implement direct delivery below.

## Current Architecture

```
Outbound: Mailu Postfix → RELAYHOST (OCI SMTP relay) → recipient
```

- `RELAYHOST=[smtp.email.eu-marseille-1.oci.oraclecloud.com]:587` in mailu.env
- SASL auth via `RELAYUSER`/`RELAYPASSWORD` (sops-encrypted)
- SPF: `v=spf1 include:_spf.mx.cloudflare.net include:eu.rp.oracleemaildelivery.com a:smtp.diegonmarcos.com ~all`
- DKIM: Mailu signs with own key (`dkim._domainkey`)
- DMARC: `p=reject`

## Target Architecture

```
Outbound: Mailu Postfix → direct MX delivery → recipient
                        ↘ (on failure) OCI SMTP relay → recipient
```

## Implementation (after port 25 is unblocked)

### Step 1: Add Postfix override for fallback relay

**File**: `a_solutions/aa-sui_tools-mailu/src/overrides/postfix/postfix.cf`

```
# Direct delivery primary, OCI relay fallback
smtp_fallback_relay = [smtp.email.eu-marseille-1.oci.oraclecloud.com]:587
smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = texthash:/overrides/postfix/sasl_passwd
smtp_sasl_security_options = noanonymous
smtp_tls_security_level = encrypt
smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt
```

Key: `texthash:` reads plaintext file directly — no `postmap` needed (Postfix 3.1+).

### Step 2: Update flake.nix — remove RELAYHOST, generate sasl_passwd

**File**: `a_solutions/aa-sui_tools-mailu/src/flake.nix`

Changes:
1. **config block**: Remove `relay_host`/`relay_port`, add `fallback_relay_host`/`fallback_relay_port` (semantic rename)
2. **mailu.env.tpl**: Remove `RELAYHOST`, `RELAYUSER`, `RELAYPASSWORD` lines (Mailu no longer handles relay)
3. **init.sh**: Generate `overrides/postfix/sasl_passwd` from secrets:
   ```
   [smtp.email.eu-marseille-1.oci.oraclecloud.com]:587 $RELAYUSER:$RELAYPASSWORD
   ```
   Keep `RELAYUSER`/`RELAYPASSWORD` in secrets.yaml and `ENV_VARS` — they're still used, just by the Postfix override instead of Mailu env.
4. **defaultPkg**: Copy `postfix.cf` to `$out/overrides/postfix/postfix.cf`
5. **init.sh**: Add `chmod 600 overrides/postfix/sasl_passwd` (credentials file)

### Step 3: Verify SPF (no change needed)

**File**: `a_solutions/ba-clo_cloudflare/src/main.tf` (live source — flake.nix is stale, build.sh copies main.tf directly)

SPF already includes both paths:
```
v=spf1 include:_spf.mx.cloudflare.net include:eu.rp.oracleemaildelivery.com a:smtp.diegonmarcos.com ~all
```

- `a:smtp.diegonmarcos.com` authorizes direct delivery (130.110.251.193)
- `include:eu.rp.oracleemaildelivery.com` authorizes OCI relay fallback
- No Cloudflare changes needed

### Step 4: Set rDNS (PTR) for oci-mail IP

For direct delivery, receiving servers check that `130.110.251.193` has a PTR record matching a forward DNS entry.

```bash
# Check current rDNS
dig -x 130.110.251.193 +short

# Set via OCI — need the public IP OCID, then update
oci network public-ip list --scope REGION --compartment-id $TENANCY
```

Target: `130.110.251.193` → `smtp.diegonmarcos.com`

### Step 5: Verify outbound port 25

```bash
ssh oci-mail "echo QUIT | nc -w3 gmail-smtp-in.l.google.com 25"
```

Must return `220` banner after Request 2 is approved.

## Files Modified

| File | Change |
|------|--------|
| `a_solutions/aa-sui_tools-mailu/src/flake.nix` | Remove RELAYHOST from env, add sasl_passwd generation in init.sh, copy postfix.cf |
| `a_solutions/aa-sui_tools-mailu/src/overrides/postfix/postfix.cf` | NEW — Postfix override with `smtp_fallback_relay` + SASL |
| `a_solutions/ba-clo_cloudflare/src/main.tf` | No change — SPF already has both direct + OCI relay authorized |

## Deployment

```bash
# 1. Build + deploy Mailu (only service that changes)
cd ~/git/cloud/a_solutions/aa-sui_tools-mailu && build.sh ship

# 2. Set rDNS via OCI CLI (if not already set)

# 3. Send test email and check headers
```

## Verification

1. Send email from `me@diegonmarcos.com` to an external address (e.g. Gmail)
2. Check email headers — should show `Received: from smtp.diegonmarcos.com` (direct), not OCI relay
3. Check SPF pass: `spf=pass` in headers
4. Check DKIM pass: `dkim=pass`
5. Send large attachment (>2MB) — should succeed without OCI 552 error
6. Simulate direct delivery failure (e.g. block port 25 temporarily) — email should route through OCI relay

## Risk Assessment

| Risk | Mitigation |
|------|-----------|
| Port 25 blocked by OCI | Fallback relay handles all delivery (same as today) |
| IP reputation issues | OCI relay fallback means delivery still works; reputation builds over time |
| DKIM mismatch | Mailu signs with own key regardless of delivery path — no change |
| SPF failure on fallback | `include:eu.rp.oracleemaildelivery.com` already in SPF covers OCI relay IPs |
| DMARC reject on direct | SPF (`a:smtp.diegonmarcos.com`) + DKIM (Mailu key) both pass — no issue |

## Prerequisites Checklist

- [ ] OCI max-message-size increased to 60MB (Request 1 — fixes bounce immediately)
- [ ] OCI outbound port 25 unblocked (Request 2 — enables direct delivery)
- [ ] Verify port 25: `ssh oci-mail "echo QUIT | nc -w3 gmail-smtp-in.l.google.com 25"`
- [ ] rDNS for 130.110.251.193 → smtp.diegonmarcos.com (`dig -x 130.110.251.193`)
