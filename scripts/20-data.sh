#!/usr/bin/env bash
# vm-data-4: SQL Server, Redis, RabbitMQ, NFS, backup
# ใช้: sudo ./20-data.sh   (หลัง 00-common.sh vm-data-4 --docker)
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../inventory.env
source "$DIR/inventory.env"

mkdir -p /srv/mssql/backup /srv/redis /srv/rabbitmq /srv/nfs/erp-files /opt/data
chown -R 10001:0 /srv/mssql        # SQL Server ใน container รันเป็น uid 10001

# NFS สำหรับไฟล์ของ erpapi (Data API)
apt-get -y install nfs-kernel-server
if ! grep -q '/srv/nfs/erp-files' /etc/exports; then
  echo "/srv/nfs/erp-files $SVC1_IP(rw,sync,no_subtree_check) $SVC2_IP(rw,sync,no_subtree_check)" >> /etc/exports
fi
exportfs -ra

for ip in "$SVC1_IP" "$SVC2_IP"; do
  ufw allow from "$ip" to any port 1433,6379,5672,2049 proto tcp
done
for net in $ADMIN_NET; do ufw allow from "$net" to any port 15672 proto tcp; done     # RabbitMQ UI

if [ ! -f /opt/data/.env ]; then
  install -m 600 "$DIR/data/.env.example" /opt/data/.env
  sed -i "s/^DATA_IP=.*/DATA_IP=$DATA_IP/" /opt/data/.env
  echo "แก้รหัสผ่านใน /opt/data/.env แล้วรัน script นี้ซ้ำ"
  exit 0
fi
# รัน compose จาก repo ตรง ๆ (repo = ต้นฉบับเดียว) ส่วนรหัสผ่านอยู่ที่ /opt/data/.env
"$DIR/data/dc.sh" up -d

install -m 750 "$DIR/data/mssql-backup.sh" /usr/local/bin/mssql-backup.sh
echo "0 1 * * * root /usr/local/bin/mssql-backup.sh >> /var/log/mssql-backup.log 2>&1" > /etc/cron.d/mssql-backup
echo "vm-data-4 พร้อม"
