#!/usr/bin/env bash
# รันบน gw-1 หลังแก้ config ใน repo
#   ./11-sync-gw.sh          sync config ไป gw-5
#   ./11-sync-gw.sh --cert   sync config + cert (หลังต่ออายุ wildcard)
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../inventory.env
source "$DIR/inventory.env"

sudo "$DIR/scripts/10-gateway.sh" "$GW_MASTER_HOST" --nginx-only
rsync -a --delete --exclude .git --exclude secrets.env "$DIR/" "root@$GW_BACKUP_IP:/opt/erp-infra/"
if [ "${1:-}" = "--cert" ]; then
  sudo rsync -a /etc/nginx/ssl/ "root@$GW_BACKUP_IP:/etc/nginx/ssl/"
fi
ssh "root@$GW_BACKUP_IP" "/opt/erp-infra/scripts/10-gateway.sh $GW_BACKUP_HOST --nginx-only"
echo "sync เสร็จทั้ง $GW_MASTER_HOST และ $GW_BACKUP_HOST"
