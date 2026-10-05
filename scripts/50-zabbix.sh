#!/usr/bin/env bash
# ติดตั้งจุดเช็กเฉพาะของ erp-infra ให้ zabbix-agent (agent ตัวหลักลงไว้แล้วโดย 00-common.sh)
# ใช้: sudo ./50-zabbix.sh      (เลือกชุดเช็กตาม hostname ของเครื่องเอง รันซ้ำได้)
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../inventory.env
source "$DIR/inventory.env"
HOST="$(hostname)"

case "$HOST" in
  "$GW_MASTER_HOST"|"$GW_BACKUP_HOST") ROLE=gw ;;
  *) echo "$HOST: ยังไม่มีชุดเช็กเฉพาะ (ตอนนี้รองรับ gateway) — ใช้ template Linux ใน Zabbix ไปก่อน"; exit 0 ;;
esac

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
install -m 644 "$DIR/monitoring/zabbix/erp-$ROLE.userparams.conf" "$INC_DIR/erp-infra.conf"

# ให้ Zabbix server ถามได้ + ชื่อ host ต้องตรงกับชื่อในหน้า Zabbix
sed -i "s/^Server=.*/Server=$ZABBIX_SERVER/; s/^ServerActive=.*/ServerActive=$ZABBIX_SERVER/; s/^Hostname=.*/Hostname=$HOST/" "$CONF"
systemctl restart zabbix-agent

echo "== ทดสอบค่าที่ Zabbix จะได้ =="
for k in erp.vip erp.cert.days 'proc.num[keepalived]' 'proc.num[nginx]' 'web.page.get[127.0.0.1,basic_status,8081]'; do
  printf '%-45s ' "$k"; zabbix_agentd -t "$k" 2>/dev/null | sed -E 's/^.*\[[a-z]\|//; s/\]$//' | tr '\n' ' '; echo
done
echo "เสร็จ: $HOST ($ROLE) · ต่อไปเพิ่ม host ในหน้า Zabbix ตาม docs/runbook.md ข้อ Monitoring"
