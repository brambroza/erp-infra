#!/usr/bin/env bash
# erp-db-01: SQL Server, Redis, RabbitMQ, NFS, backup
# ใช้: sudo ./20-data.sh   (หลัง 00-common.sh erp-db-01 --docker)
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../inventory.env
source "$DIR/inventory.env"

mkdir -p /srv/mssql/backup /srv/redis /srv/rabbitmq /srv/nfs/erp-files /opt/data
chown -R 10001:0 /srv/mssql        # SQL Server ใน container รันเป็น uid 10001

# NFS สำหรับไฟล์ของ erpapi (Data API)
apt-get -y install nfs-kernel-server
# erpapi รันเป็น uid 5678 แต่ chat-api รันเป็น root (เครื่องเดิมใช้ --user 0:0) และเขียนโฟลเดอร์เดียวกัน
# all_squash + anonuid=5678 → ทุก client เขียนเป็นเจ้าของ 5678 เหมือนกัน (root ไม่โดน squash เป็น nobody จนเขียนไม่ได้)
NFS_OPTS="rw,sync,no_subtree_check,all_squash,anonuid=5678,anongid=5678"
sed -i '\#^/srv/nfs/erp-files #d' /etc/exports
echo "/srv/nfs/erp-files $SVC1_IP($NFS_OPTS) $SVC2_IP($NFS_OPTS)" >> /etc/exports
# erpapi รันเป็น appuser uid 5678 (Dockerfile ของ go-coreapi) — ต้องเขียนไฟล์ได้ผ่าน NFS
chown 5678:5678 /srv/nfs/erp-files
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

# คิว webhook ของ chat-api (fb/whatsapp/shopee/lazada/tiktok/internalChat) ไม่มี consumer → ข้อความกองไม่มีวันหมด
# ถ้าปล่อยไว้ RabbitMQ จะชน memory alarm แล้ว block ทุก publisher รวมถึง log_queue ของ erpapi
# จำกัดคิวละ 10,000 ข้อความ เก็บ 7 วัน เกินแล้วทิ้งตัวเก่าสุด
for i in $(seq 30); do "$DIR/data/dc.sh" exec -T rabbitmq rabbitmq-diagnostics -q ping >/dev/null 2>&1 && break; sleep 2; done
"$DIR/data/dc.sh" exec -T rabbitmq rabbitmqctl set_policy --apply-to queues cap-webhook-queues \
  '^(fb|whatsapp|shopee|lazada|tiktok|internalChat)Queue$' \
  '{"max-length":10000,"message-ttl":604800000,"overflow":"drop-head"}'

install -m 750 "$DIR/data/mssql-backup.sh" /usr/local/bin/mssql-backup.sh
echo "0 1 * * * root /usr/local/bin/mssql-backup.sh >> /var/log/mssql-backup.log 2>&1" > /etc/cron.d/mssql-backup
echo "erp-db-01 พร้อม"
