# Security

Security architecture layers.

## Defense Stack

| Layer | Components |
|-------|------------|
| Network Edge | Cloud Firewalls, UFW |
| Traffic | NPM Proxy, TLS/SSL |
| Authentication | Authelia 2FA, OIDC |
| Application | Docker Networks, Container Isolation |
| Credentials | Bitwarden, Aegis TOTP |

## TLS Certificates

| Domain | Provider | Auto-Renew |
|--------|----------|------------|
| *.diegonmarcos.com | Let's Encrypt | Yes |
| *.app.diegonmarcos.com | Let's Encrypt | Yes |

## Access Control

| Service | Auth Method |
|---------|-------------|
| NPM Admin | Authelia 2FA |
| Portainer | Local + 2FA |
| Photoprism | Password |
| Mail | IMAP/SMTP Auth |
