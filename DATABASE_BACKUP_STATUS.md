# Database Backup Status

> **Generated**: 2026-02-05
> **Status**: Flex VM backup infrastructure deployed

## Database Inventory

| Server | Service | DB Type | Container | Size | Backup |
|--------|---------|---------|-----------|------|--------|
| **gcp-f-micro_1** | NPM | SQLite | sqlite-npm (ws4sqlite) | 200KB | ❌ |
| | Vaultwarden | SQLite | sqlite-vaultwarden (ws4sqlite) | ? | ❌ |
| | ntfy | SQLite | sqlite-ntfy (ws4sqlite) | ? | ❌ |
| | Authelia | Redis | authelia-redis | in-mem | ❌ |
| **oci-f-micro_1** | Mailu | Redis | mailu-redis | in-mem | ❌ |
| **oci-f-micro_2** | Matomo | MariaDB 10.11 | matomo-db | ? | ❌ |
| **oci-p-flex_1** | NocoDB | PostgreSQL 16 | nocodb-db | 924KB | ✅ bup |
| | Photoprism | MariaDB | photoprism-db | ? | ❌ |

## Summary

| DB Type | Count | Backup Tool | Status |
|---------|-------|-------------|--------|
| SQLite | 3 | Litestream | ❌ Not deployed |
| PostgreSQL | 1 | pgBackRest | ❌ Not deployed |
| MariaDB | 2 | mariabackup | ❌ Not deployed |
| Redis | 2 | RDB snapshots | ❌ Not deployed |

**Total: 8 databases, 1 backup configured (NocoDB on Flex)**

## Recommended Backup Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        BACKUP PIPELINE                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  SQLite (npm, vaultwarden, ntfy)                               │
│  └── Litestream → S3/B2 (continuous WAL streaming)             │
│                                                                 │
│  PostgreSQL (nocodb)                                            │
│  └── pgBackRest → S3/B2 (incremental, PITR)                    │
│                                                                 │
│  MariaDB (matomo, photoprism)                                   │
│  └── mariabackup → S3/B2 (incremental)                         │
│                                                                 │
│  Redis (authelia, mailu)                                        │
│  └── RDB snapshots → S3/B2 (periodic)                          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Backup Tools

| DB Type | Tool | Features |
|---------|------|----------|
| SQLite | **Litestream** | Continuous WAL replication, S3/B2 native |
| PostgreSQL | **pgBackRest** | Incremental, parallel, PITR, S3 native |
| MariaDB | **mariabackup** | Hot backup, incremental, compressed |
| Redis | **RDB/AOF** | Built-in snapshots, can sync to S3 |

## Storage Targets

| Provider | Free Tier | Use Case |
|----------|-----------|----------|
| Oracle Object Storage | 10GB | Primary |
| Backblaze B2 | 10GB | Secondary |
| Cross-VM rsync | ∞ | Quick recovery |

## Backup Architecture

Three-tier backup to Flex VM (no cloud storage needed):

| Tier | Tool | Data | Dedup |
|------|------|------|-------|
| **Code** | Gitea | Git repos | Git packfiles |
| **Databases** | bup | SQL dumps | Git packfiles |
| **Media** | Borg | Photos, files | Content-chunking |

## Configs

Location: `a_solutions/all/back-backup/`

```
back-backup/
├── README.md           # Full documentation
├── deploy.sh           # One-command deployment
├── gitea/              # Code mirrors
├── bup/                # Database backups
└── borg/               # Media backups
```

## Deploy

```bash
cd a_solutions/all/back-backup
./deploy.sh
```

## Status (2026-02-05)

- [x] Flex VM backup infrastructure deployed
- [x] Gitea running at http://144.24.196.72:3000
- [x] GitHub mirrors: cloud ✓, unix ✓ (front/vault need GitHub token for private repos)
- [x] bup repository initialized, NocoDB backup tested (924KB)
- [x] Cron jobs configured (3 AM: databases, 4 AM: media)

## TODO

- [ ] Add GitHub token for private repo mirrors (front, vault)
- [ ] Deploy bup backup scripts to GCP and Micro VMs
- [ ] Test full media backup with Borg
- [ ] Test database restore from bup
