#!/usr/bin/env bash
# ติดตั้งจุดเช็กเฉพาะของ erp-infra ให้ zabbix-agent (agent ตัวหลักลงไว้แล้วโดย 00-common.sh)
# ใช้: sudo ./50-zabbix.sh      (เลือกชุดเช็กตาม hostname ของเครื่องเอง รันซ้ำได้)
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../inventory.env
source "$DIR/inventory.env"
HOST="$(hostname)"

# ชุดเช็กตามบทบาท → ไฟล์ monitoring/zabbix/erp-<ชุด>.userparams.conf
case "$HOST" in
  "$GW_MASTER_HOST"|"$GW_BACKUP_HOST") SETS="gw";            KEYS="erp.vip erp.cert.days proc.num[keepalived] proc.num[nginx] web.page.get[127.0.0.1,basic_status,8081]" ;;
  "$SVC1_HOST")                        SETS="node manager";  KEYS="erp.node.containers erp.node.nfs proc.num[dockerd] erp.swarm.nodes.bad erp.swarm.failed erp.swarm.missing[erp_erpapi] erp.swarm.discovery" ;;
  "$DATA_HOST")                        SETS="data";          KEYS="erp.db[collect_age] erp.db[srv_mounted] erp.db[backup_age_h] erp.db[backup_size_mb] erp.db[c_mssql] erp.db[c_redis] erp.db[c_rabbitmq] erp.db[mssql_online] erp.db[mssql_data_mb] erp.db[redis_ping] erp.db[redis_mem_pct] erp.db[rabbit_ok] erp.db[rabbit_alarm] erp.db[rabbit_max_queue] erp.db[nfs_server] erp.db[nfs_export]" ;;
  "$SVC2_HOST")                        SETS="node";          KEYS="erp.node.containers erp.node.nfs proc.num[dockerd]" ;;
  *) echo "$HOST: ยังไม่มีชุดเช็กเฉพาะ — ใช้ template Linux ใน Zabbix ไปก่อน"; exit 0 ;;
esac
ROLE="${SETS// /+}"

command -v zabbix_agentd >/dev/null || { echo "ไม่พบ zabbix_agentd — รัน 00-common.sh ก่อน" >&2; exit 1; }
CONF=/etc/zabbix/zabbix_agentd.conf
# Include ของ agent (Ubuntu ใช้ zabbix_agentd.conf.d, repo ของ Zabbix ใช้ zabbix_agentd.d)
INC_DIR=$(grep -E '^Include=' "$CONF" | head -1 | sed -E 's/^Include=//; s#/\*\.conf$##; s#/$##')
if [ -z "$INC_DIR" ]; then
  INC_DIR=/etc/zabbix/zabbix_agentd.conf.d
  echo "Include=$INC_DIR/*.conf" >> "$CONF"
fi
mkdir -p "$INC_DIR"

sed "s/__VIP__/$VIP/" "$DIR/monitoring/zabbix/erp-zbx.sh" > /usr/local/bin/erp-zbx.sh
chmod 755 /usr/local/bin/erp-zbx.sh
cat $(for x in $SETS; do echo "$DIR/monitoring/zabbix/erp-$x.userparams.conf"; done) > "$INC_DIR/erp-infra.conf"
chmod 644 "$INC_DIR/erp-infra.conf"

# คำสั่ง docker ต้องใช้ root → อนุญาต user zabbix เรียก sudo ได้เฉพาะ script นี้ (ไม่เพิ่มเข้า group docker)
if [ "$SETS" = "data" ]; then
  # เก็บค่าทุกนาทีด้วย root (อ่าน /opt/data/.env ได้) แล้วเขียนไฟล์ที่ไม่มีความลับให้ Zabbix อ่าน
  echo '* * * * * root /usr/local/bin/erp-zbx.sh db-collect >/dev/null 2>&1' > /etc/cron.d/erp-zbx-db
  chmod 644 /etc/cron.d/erp-zbx-db
  echo "เก็บค่ารอบแรก (ราว 10–20 วินาที)..."
  /usr/local/bin/erp-zbx.sh db-collect
fi
if [ "$SETS" = "node" ] || [ "$SETS" = "node manager" ]; then
  echo 'zabbix ALL=(root) NOPASSWD: /usr/local/bin/erp-zbx.sh' > /etc/sudoers.d/zabbix-erp
  chmod 440 /etc/sudoers.d/zabbix-erp
  visudo -cf /etc/sudoers.d/zabbix-erp >/dev/null
  # docker service ps หลายตัวใช้เวลา → ขยาย timeout ของ agent (ค่าเริ่มต้น 3 วินาที)
  if grep -qE '^Timeout=' "$CONF"; then sed -i 's/^Timeout=.*/Timeout=15/' "$CONF"; else echo 'Timeout=15' >> "$CONF"; fi
fi

# ให้ Zabbix server ถามได้ + ชื่อ host ต้องตรงกับชื่อในหน้า Zabbix
sed -i "s/^Server=.*/Server=$ZABBIX_SERVER/; s/^ServerActive=.*/ServerActive=$ZABBIX_SERVER/; s/^Hostname=.*/Hostname=$HOST/" "$CONF"
systemctl restart zabbix-agent

echo "== ทดสอบค่าที่ Zabbix จะได้ =="
set -f   # key มี [ ] ห้าม shell ขยายเป็นชื่อไฟล์
for k in $KEYS; do
  printf '%-45s ' "$k"; sudo -u zabbix zabbix_agentd -t "$k" 2>/dev/null | sed -E 's/^.*\[[a-z]\|//; s/\]$//' | tr '\n' ' ' | cut -c1-120; echo
done
echo "เสร็จ: $HOST ($ROLE) · ต่อไปเพิ่ม host ในหน้า Zabbix ตาม docs/runbook.md ข้อ Monitoring"
