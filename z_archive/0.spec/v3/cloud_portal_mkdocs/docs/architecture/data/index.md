# Data

Data layer architecture.

## Databases

| Type | Service | VM | Purpose |
|------|---------|-----|---------|
| SQLite | Authelia | gcp-f-micro_1 | Auth sessions |
| SQLite | NPM | gcp-f-micro_1 | Proxy configs |
| MariaDB | Matomo | oci-f-micro_2 | Analytics |
| MariaDB | Photoprism | oci-p-flex_1 | Photo metadata |

## Storage

| VM | Total | Used | Available |
|----|-------|------|-----------|
| oci-f-micro_1 | 47 GB | ~5 GB | ~42 GB |
| oci-f-micro_2 | 47 GB | ~8 GB | ~39 GB |
| gcp-f-micro_1 | 30 GB | ~4 GB | ~26 GB |
| oci-p-flex_1 | 100 GB | ~40 GB | ~60 GB |
