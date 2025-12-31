# Container Topology

## Docker Networks

| Network | Subnet | VM |
|---------|--------|-----|
| mail_network | 172.20.0.0/24 | oci-f-micro_1 |
| matomo_network | 172.21.0.0/24 | oci-f-micro_2 |
| proxy_network | 172.23.0.0/24 | gcp-f-micro_1 |
| dev_network | 172.24.0.0/24 | oci-p-flex_1 |

## Containers by VM

### oci-f-micro_1
- mailu-front, mailu-admin, mailu-smtp, mailu-imap, mailu-antispam, mailu-webmail, mailu-fetchmail, mailu-redis

### oci-f-micro_2
- matomo-app, matomo-db

### gcp-f-micro_1
- npm, authelia, flask-api

### oci-p-flex_1
- photoprism, syncthing, radicale
