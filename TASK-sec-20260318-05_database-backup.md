# Database Backup

> **Date**: 2026-03-18
> **Updated**: 2026-03-18
> **Status**: Partial — Flex has backups, GCP/Micros mostly unprotected
> **Depends on**: TASK-sec-03 (stable networking/firewall before backup infra)
> **Replaces**: TASK-00

---

## Checklist

- [ ] Add Vaultwarden SQLite backup (systemd timer on GCP, same as Authelia)
- [ ] Add bup jobs for Etherpad, HedgeDoc, PhotoPrism on Flex
- [ ] Deploy bup backup scripts to GCP and Micro VMs
- [ ] Add GitHub token for private repo mirrors (front, vault)
- [ ] Test database restore from bup
- [ ] Add Matomo mysqldump cron on oci-analytics
- [ ] Add Windmill pg_dump cron on oci-analytics
- [ ] All backup jobs declared in home-manager or service flakes (NEVER imperative cron)

---

## Database Inventory

| Server | Service | DB Type | Container | Backup | Notes |
|--------|---------|---------|-----------|--------|-------|
| **gcp-proxy** | Vaultwarden | SQLite | vaultwarden | :x: | DATA LOSS = catastrophic |
| | Authelia | SQLite | authelia | :white_check_mark: systemd timer | Daily 3AM, 7 rolling copies |
| | Authelia sessions | Redis | authelia-redis | :x: | In-memory, ephemeral (acceptable) |
| | ntfy | SQLite | ntfy | :x: | Low priority |
| **oci-apps** | NocoDB | PostgreSQL 16 | nocodb-db | :white_check_mark: bup cron | Daily 3AM via bup |
| | NocoDB (front) | PostgreSQL 16 | nocodb_postgres | :white_check_mark: bup cron | Same bup job |
| | PhotoPrism | MariaDB 10.11 | photoprism-db | :x: | No backup configured |
| | Etherpad | PostgreSQL 16 | etherpad_postgres | :x: | No backup configured |
| | HedgeDoc | PostgreSQL 16 | hedgedoc_postgres | :x: | No backup configured |
| | Mattermost | PostgreSQL | mattermost-db | :x: | No backup configured |
| | Redis | Redis | redis | :x: | AOF enabled, no offsite |
| **oci-analytics** | Matomo | MariaDB 10.11 | matomo-db | :x: | No cron, no backup scripts |
| | Windmill | PostgreSQL 16 | windmill-db | :x: | No backup configured |

## Summary

| Status | Count |
|--------|-------|
| :white_check_mark: Backed up | 3 |
| :x: No backup | 10+ |
| Ephemeral (OK) | 1 |

---

## Critical Missing Backups (Priority Order)

1. **Vaultwarden** (gcp-proxy) — Password vault, DATA LOSS = catastrophic
2. **Mattermost PostgreSQL** (oci-apps) — Chat history
3. **PhotoPrism MariaDB** (oci-apps) — Photo metadata/indexes
4. **Matomo MariaDB** (oci-analytics) — Analytics data
5. **Windmill PostgreSQL** (oci-analytics) — Workflow configurations

---

## Implementation

All backup jobs MUST be declared in home-manager modules or service flakes. No imperative `crontab -e` or manual scripts on VMs.

### Pattern: systemd timer (home-manager)

```nix
# In service flake.nix or home-manager module
systemd.services.backup-vaultwarden = {
  description = "Vaultwarden SQLite backup";
  serviceConfig.Type = "oneshot";
  script = ''
    sqlite3 /path/to/db.sqlite3 ".backup /path/to/backups/vaultwarden-$(date +%Y%m%d).sqlite3"
    # Keep last 7 copies
    ls -1t /path/to/backups/vaultwarden-*.sqlite3 | tail -n +8 | xargs rm -f
  '';
};

systemd.timers.backup-vaultwarden = {
  wantedBy = [ "timers.target" ];
  timerConfig.OnCalendar = "daily";
  timerConfig.Persistent = true;
};
```

### Pattern: pg_dump + bup (for PostgreSQL)

```bash
docker exec nocodb-db pg_dump -U postgres > /backups/nocodb-$(date +%Y%m%d).sql
bup index /backups/
bup save -n backups /backups/
```
