# Security Check - Gates of Entry

**Updated:** 2025-12-12
**Model:** Passwordless Environment

---

## Entry Points Overview

```
                              ┌─────────────────────────────────────┐
                              │         GATES OF ENTRY              │
                              └─────────────────────────────────────┘
                                              │
        ┌───────────────┬───────────────┬─────┴─────┬───────────────┐
        ▼               ▼               ▼           ▼               ▼
   ┌─────────┐    ┌─────────┐    ┌───────────┐ ┌─────────┐    ┌─────────┐
   │   SSH   │    │Authelia │    │ IMAP/SMTP │ │   OCI   │    │   GCI   │
   │  (RSA)  │    │(Pass+2FA)│   │  (Token)  │ │ Console │    │ Console │
   └────┬────┘    └────┬────┘    └─────┬─────┘ └────┬────┘    └────┬────┘
        │              │               │            │              │
        ▼              ▼               ▼            ▼              ▼
   ┌─────────┐    ┌─────────┐    ┌───────────┐ ┌─────────┐    ┌─────────┐
   │  VMs    │    │Web Apps │    │Email Clnts│ │Oracle   │    │Google   │
   │(no pass)│    │(no pass)│    │           │ │Cloud    │    │Cloud    │
   └─────────┘    └─────────┘    └───────────┘ └─────────┘    └─────────┘
```

---

## Gate 1: SSH (RSA Key)

**Auth:** Private key (no password)
**Key Location:** `LOCAL_KEYS/00_terminal/ssh/`

### Surface Pro 8 (Local Machine)
| Target | IP | User | Key | Services |
|--------|-----|------|-----|----------|
| Oracle Web Server 1 | 130.110.251.193 | ubuntu | id_rsa | Mailu, Matomo, Syncthing |
| GCloud Arch 1 | 34.55.55.234 | diego | google_compute_engine | NPM, Authelia |

```bash
# Oracle VM
ssh -i ~/.ssh/id_rsa ubuntu@130.110.251.193

# Google Cloud VM
gcloud compute ssh arch-1 --zone=us-central1-a
```

---

## Gate 2: Authelia (Password + 2FA)

**Auth:** Password + TOTP/WebAuthn (single sign-on)
**URL:** https://auth.diegonmarcos.com/authelia/
**User:** me@diegonmarcos.com
**2FA:** Aegis (TOTP) or YubiKey (WebAuthn)

### Protected Services (no additional password needed)
| Service | URL | Backend |
|---------|-----|---------|
| Photo Gallery | https://photos.diegonmarcos.com | Oracle VM 1 |
| Matomo Analytics | https://analytics.diegonmarcos.com | Oracle VM 1 |
| Syncthing | https://sync.diegonmarcos.com | Oracle VM 1 |
| Cloud Dashboard | https://cloud.diegonmarcos.com | GitHub Pages |
| Mail Webmail | https://mail.diegonmarcos.com/webmail | Oracle VM 1 |
| Mail Admin | https://mail.diegonmarcos.com/admin | Oracle VM 1 |
| NPM Proxy Admin | https://proxy.diegonmarcos.com | GCloud VM (127.0.0.1:81) |

---

## Gate 3: IMAP/SMTP (Token)

**Auth:** 32-char token password (exception - can't use Authelia)
**Reason:** Email clients (Thunderbird, mobile) don't support web 2FA

| Protocol | Server | Port | Encryption |
|----------|--------|------|------------|
| IMAP | imap.diegonmarcos.com | 993 | SSL/TLS |
| SMTP | smtp.diegonmarcos.com | 465 | SSL/TLS |

**Credentials:**
- User: `me@diegonmarcos.com`
- Token: `<REDACTED-LEAK-2026-04-21>`

---

## Gate 4: OCI Console (Oracle Cloud Infrastructure)

**Auth:** Oracle SSO + 2FA
**URL:** https://cloud.oracle.com
**Tenancy:** Frankfurt (eu-frankfurt-1)

### Resources Accessible
| Resource | Type | Purpose |
|----------|------|---------|
| Oracle Web Server 1 | VM.Standard.E2.1.Micro | Mailu, Matomo, Syncthing |
| VCN | Virtual Network | Networking |
| Block Volumes | Storage | VM disks |

### CLI Access
**Config:** `LOCAL_KEYS/00_terminal/oracle/`
```bash
oci compute instance list --compartment-id <compartment>
```

---

## Gate 5: GCI Console (Google Cloud Infrastructure)

**Auth:** Google SSO + 2FA
**URL:** https://console.cloud.google.com
**Project:** diego-cloud

### Resources Accessible
| Resource | Type | Purpose |
|----------|------|---------|
| arch-1 | e2-micro | NPM, Authelia, OAuth2-Proxy |
| VPC | Virtual Network | Networking |
| Firewall Rules | Security | Port access |

### CLI Access
**Config:** `LOCAL_KEYS/00_terminal/gcloud/`
```bash
gcloud compute instances list
gcloud compute ssh arch-1 --zone=us-central1-a
```

---

## Gate 6: API Access (Tokens/Keys)

| Service | Auth Type | Location |
|---------|-----------|----------|
| Cloudflare | API Key | LOCAL_KEYS/SPEC.md |
| Gmail SMTP | App Password | LOCAL_KEYS/SPEC.md |
| GitHub CLI | OAuth Token | LOCAL_KEYS/00_terminal/github/ |
| OCI CLI | API Key | LOCAL_KEYS/00_terminal/oracle/ |
| GCloud CLI | OAuth | LOCAL_KEYS/00_terminal/gcloud/ |

---

## Security Matrix

| Gate | Auth Method | 2FA | Password Needed After |
|------|-------------|-----|----------------------|
| SSH | RSA Key | No | No |
| Authelia | Password | Yes (TOTP/WebAuthn) | No (SSO) |
| IMAP/SMTP | Token | No | N/A |
| OCI Console | Oracle SSO | Yes | No |
| GCI Console | Google SSO | Yes | No |
| APIs | Token/Key | No | No |

---

## Device Trust Chain

```
┌──────────────────────────────────────────────────────────────────┐
│                     SURFACE PRO 8 (Local)                        │
│                                                                  │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐              │
│  │ SSH Keys    │  │ CLI Configs │  │ Browser     │              │
│  │ (id_rsa)    │  │ (oci/gcloud)│  │ (Bitwarden) │              │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘              │
│         │                │                │                      │
│         ▼                ▼                ▼                      │
│  ┌─────────────────────────────────────────────────┐            │
│  │              LOCAL_KEYS Vault                    │            │
│  │         (Syncthing encrypted sync)              │            │
│  └─────────────────────────────────────────────────┘            │
└──────────────────────────────────────────────────────────────────┘
         │                 │                │
         ▼                 ▼                ▼
    ┌─────────┐      ┌─────────┐      ┌─────────┐
    │Oracle   │      │Google   │      │Cloudflare│
    │VMs      │      │VMs      │      │DNS      │
    └─────────┘      └─────────┘      └─────────┘
```

---

## Passwordless Exceptions

| Service | Why Password Needed | Mitigation |
|---------|---------------------|------------|
| Authelia | Entry gate (1st factor) | Strong password + 2FA |
| IMAP/SMTP | Protocol limitation | 32-char random token |

**Note:** NPM Admin is protected via https://proxy.diegonmarcos.com (Authelia 2FA).
Direct access to http://34.55.55.234:81 should be blocked by firewall.
