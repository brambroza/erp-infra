#!/usr/bin/env bash
# full backup ทุกคืน (cron 01:00) เก็บในเครื่อง 7 วัน แล้ว copy ไปนอกเครื่อง
set -euo pipefail
set -a
# shellcheck disable=SC1091
source /opt/data/.env
set +a
STAMP=$(date +%F_%H%M)

for db in $MSSQL_BACKUP_DBS; do
  /opt/erp-infra/data/dc.sh exec -T -e SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" mssql \
    /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b \
    -Q "BACKUP DATABASE [$db] TO DISK='/var/opt/mssql/backup/${db}_${STAMP}.bak' WITH COMPRESSION, CHECKSUM, INIT"
done

find /srv/mssql/backup -name '*.bak' -mtime +7 -delete

if [ -n "${BACKUP_TARGET:-}" ]; then
  rsync -a /srv/mssql/backup/ "$BACKUP_TARGET"
  rsync -a /srv/nfs/erp-files/ "${BACKUP_TARGET%/}-files/"
fi
echo "$(date -Is) backup ok: $MSSQL_BACKUP_DBS"
