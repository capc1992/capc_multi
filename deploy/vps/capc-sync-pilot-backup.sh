#!/usr/bin/env bash
set -Eeuo pipefail

readonly backup_dir='/var/backups/capc-sync-pilot'
readonly timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
readonly final_file="${backup_dir}/capc-sync-pilot-${timestamp}.dump"
readonly temporary_file="${final_file}.tmp"

install -d -o postgres -g postgres -m 0750 "$backup_dir"
runuser -u postgres -- pg_dump --format=custom --file="$temporary_file" capc_sync_pilot
mv "$temporary_file" "$final_file"
find "$backup_dir" -maxdepth 1 -type f -name 'capc-sync-pilot-*.dump' -mtime +14 -delete

echo "Respaldo PostgreSQL del piloto creado: $final_file"
