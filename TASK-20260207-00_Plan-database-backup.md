# Database Backup Status

> **Date**: 2026-02-07
> **Updated**: 2026-02-07
> **Status**: Partial — Flex has backups, GCP/Micros mostly unprotected

---

## Checklist

- [ ] Add Vaultwarden SQLite backup (systemd timer on GCP, same as Authelia)
- [ ] Add bup jobs for Etherpad, HedgeDoc, PhotoPrism on Flex
- [ ] Deploy bup backup scripts to GCP and Micro VMs
- [ ] Add GitHub token for private repo mirrors (front, vault)
- [ ] Test database restore from bup
- [ ] Add Matomo mysqldump cron on Micro1
- [ ] Add Windmill pg_dump cron on Micro2

---

## Database Inventory

| Server | Service | DB Type | Container | Backup | Notes |
|--------|---------|---------|-----------|--------|-------|
| **gcp-f-micro_1** | NPM | SQLite | npm | ❌ | `/home/diego/npm/data/database.sqlite` |
| | Vaultwarden | SQLite | vaultwarden | ❌ | `/home/diego/vaultwarden/data/db.sqlite3` |
| | ntfy | SQLite | ntfy | ❌ | `/home/diego/ntfy/cache/cache.db` (low priority) |
| | Authelia | SQLite | authelia | ✅ systemd timer | Daily 3AM → `/home/diego/backups/authelia/` (7 copies) |
| | Authelia sessions | Redis | authelia-redis | ❌ | In-memory, ephemeral (acceptable) |
| **oci-p-flex_1** | NocoDB | PostgreSQL 16 | nocodb-db | ✅ bup cron | Daily 3AM via `bup` |
| | NocoDB (front) | PostgreSQL 16 | nocodb_postgres | ✅ bup cron | Same bup job |
| | PhotoPrism | MariaDB 10.11 | photoprism-db | ❌ | No backup configured |
| | PhotoPrism (front) | MariaDB 11 | photoprism_mariadb | ❌ | No backup configured |
| | Etherpad | PostgreSQL 16 | etherpad_postgres | ❌ | No backup configured |
| | HedgeDoc | PostgreSQL 16 | hedgedoc_postgres | ❌ | No backup configured |
| | Redis | Redis | redis | ❌ | AOF enabled, no offsite |
| **oci-f-micro_1** | Matomo | MariaDB 10.11 | matomo-db | ❌ | No cron, no backup scripts |
| | Stalwart Mail | Internal | stalwart-mail | ❌ | No backup configured |
| **oci-f-micro_2** | Matomo | MariaDB (hybrid) | matomo-hybrid | ❌ | Old manual backup exists |
| | Windmill | PostgreSQL 16 | windmill-db | ❌ | No backup configured |

## Summary

| Status | Count | Details |
|--------|-------|---------|
| ✅ Backed up | 3 | Authelia SQLite, NocoDB Postgres (x2) |
| ❌ No backup | 12 | NPM, Vaultwarden, ntfy, PhotoPrism (x2), Etherpad, HedgeDoc, Redis, Matomo (x2), Stalwart, Windmill |
| ℹ Ephemeral (OK) | 1 | Authelia Redis (sessions) |

**Total: 16 databases, 3 backed up**

## Active Backup Infrastructure

### Flex VM (oci-p-flex_1)
- **bup** cron at 3AM: backs up NocoDB Postgres via `pg_dump`
- **borg** cron at 4AM: backs up media files (photos, filebrowser)
- **Gitea** mirrors: cloud, unix repos

### GCP (gcp-f-micro_1)
- **systemd timer** `authelia-backup.timer`: daily 3AM SQLite `.backup` → 7 rolling copies

## Critical Missing Backups

1. **Vaultwarden** (GCP) — Password vault, DATA LOSS = catastrophic
2. **PhotoPrism MariaDB** (Flex) — Photo metadata/indexes
3. **Matomo MariaDB** (Micro1) — Analytics data
4. **Windmill Postgres** (Micro2) — Workflow configurations
