#!/bin/bash
# Authelia SQLite backup - keeps 7 daily copies
BACKUP_DIR="/home/diego/backups/authelia"
DB="/home/diego/authelia/config/db.sqlite3"
STAMP=$(date +%Y%m%d_%H%M%S)

# Use sqlite3 .backup for consistent copy (no corruption from active writes)
if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$DB" ".backup ${BACKUP_DIR}/db_${STAMP}.sqlite3"
else
    cp "$DB" "${BACKUP_DIR}/db_${STAMP}.sqlite3"
fi

# Keep only last 7 backups
ls -t ${BACKUP_DIR}/db_*.sqlite3 2>/dev/null | tail -n +8 | xargs rm -f 2>/dev/null

echo "$(date): Backup completed -> db_${STAMP}.sqlite3" >> ${BACKUP_DIR}/backup.log
