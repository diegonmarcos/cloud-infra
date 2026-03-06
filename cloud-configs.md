
# Cloud Configs

> Auto-generated from `cloud-configs.json`. Run `./build.sh config` to regenerate.

## Infrastructure

### Caddy Routes

| Domain | Upstream | Auth | TLS Skip | Public Paths |
|--------|----------|------|----------|--------------|
| auth.diegonmarcos.com | authelia:9091 | none | no | — |
| api.diegonmarcos.com/c3-api | 10.0.0.6:8081 | authelia+bearer | no | — |
| api.diegonmarcos.com/rust-api | 10.0.0.6:8080 | authelia+bearer | no | — |
| api.diegonmarcos.com/flask | 10.0.0.1:5000 | authelia+bearer | no | — |
| api.diegonmarcos.com/crawlee | 10.0.0.6:3000 | authelia+bearer | no | — |
| cal.diegonmarcos.com | 10.0.0.6:5232 | none | no | — |
| chat.diegonmarcos.com | 10.0.0.6:8065 | authelia+bearer | no | — |
| drive-notes-affine.diegonmarcos.com | 10.0.0.6:3010 | none | no | — |
| analytics.diegonmarcos.com | 10.0.0.4:8080 | authelia+bearer | no | /matomo.js, /matomo.php, /piwik.js, /piwik.php, /collect.php, /api.php, /track.php, /js/* |
| photos.diegonmarcos.com | 10.0.0.6:3013 | authelia+bearer | no | — |
| mail.diegonmarcos.com | 10.0.0.3:8444 | authelia+bearer | yes | — |
| workflows.diegonmarcos.com | 10.0.0.3:8070 | authelia+bearer | no | — |
| ide.diegonmarcos.com | 10.0.0.6:8443 | authelia+bearer | no | — |
| db.diegonmarcos.com | 10.0.0.6:8085 | authelia+bearer | no | — |
| app.diegonmarcos.com/windmill | 10.0.0.4:8000 | authelia+bearer | no | — |
| app.diegonmarcos.com/etherpad | 10.0.0.6:3012 | authelia+bearer | no | — |
| app.diegonmarcos.com/filebrowser | 10.0.0.6:3015 | authelia+bearer | no | — |
| app.diegonmarcos.com/hedgedoc | 10.0.0.6:3018 | authelia+bearer | no | — |
| app.diegonmarcos.com/revealmd | 10.0.0.6:3014 | authelia+bearer | no | — |
| app.diegonmarcos.com/dozzle | 10.0.0.1:9999 | authelia+bearer | no | — |
| app.diegonmarcos.com/grafana | 10.0.0.6:3016 | authelia+bearer | no | — |
| app.diegonmarcos.com/gitea | 10.0.0.6:3017 | authelia+bearer | no | — |
| app.diegonmarcos.com/crawlee | 10.0.0.6:3001 | authelia+bearer | no | — |
| sheets.diegonmarcos.com | 10.0.0.6:3011 | authelia+bearer | no | — |
| proxy.diegonmarcos.com | static | authelia+bearer | no | — |
| vault.diegonmarcos.com | vaultwarden:80 | authelia+bearer | no | — |
| rss.diegonmarcos.com | ntfy:80 | 3-tier | no | — |


### Authelia ACL

| Domain | Policy | Resources |
|--------|--------|-----------|
| auth.diegonmarcos.com | bypass | — |
| vault.diegonmarcos.com | bypass | ^/api.*, ^/identity.*, ^/icons.*, ^/notifications.*, ^/attachments.* |
| vault.diegonmarcos.com | two_factor | ^/admin.* |
| vault.diegonmarcos.com | bypass | — |
| db.diegonmarcos.com | bypass | ^/api/.* |
| db.diegonmarcos.com | two_factor | — |
| *.diegonmarcos.com | two_factor | — |


### Hickory DNS

#### Zone: 0.0.10.in-addr.arpa

| Name | Type | Value | Comment |
|------|------|-------|---------|
| 1 | PTR | gcp-proxy.internal. | — |
| 3 | PTR | oci-mail.internal. | — |
| 4 | PTR | oci-analytics.internal. | — |
| 6 | PTR | oci-apps.internal. | — |

#### Zone: internal

| Name | Type | Value | Comment |
|------|------|-------|---------|
| affine | A | 10.0.0.6 | AFFiNE |
| api | A | 10.0.0.1 | API gateway |
| auth | A | 10.0.0.1 | Authelia 2FA |
| caddy | A | 10.0.0.1 | Reverse proxy |
| cal | A | 10.0.0.3 | Radicale |
| db | A | 10.0.0.6 | NocoDB |
| dns | A | 10.0.0.1 | Hickory DNS |
| ide | A | 10.0.0.6 | Code Server |
| mail | A | 10.0.0.3 | Mailu |
| matomo | A | 10.0.0.4 | Matomo analytics |
| ntfy | A | 10.0.0.1 | Push notifications |
| photos | A | 10.0.0.6 | PhotoPrism |
| sync | A | 10.0.0.3 | Syncthing |
| vault | A | 10.0.0.1 | Vaultwarden |
| windmill | A | 10.0.0.4 | Windmill workflows |
| * | A | 10.0.0.1 | — |




## Applications

### Ntfy

| Setting | Value |
|---------|-------|
| Topics |  |
| Users | diego |
| Enable_login | true |
| Auth_default_access | read-write |

### Mailu

| Setting | Value |
|---------|-------|
| Domain | diegonmarcos.com |
| Mailboxes | no-reply@diegonmarcos.com |
| Relay | [smtp.email.eu-marseille-1.oci.oraclecloud.com]:587 |

