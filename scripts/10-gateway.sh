#!/usr/bin/env bash
# ติดตั้ง Nginx + keepalived บน gateway
# ใช้: sudo ./10-gateway.sh gw-1|gw-2 [--nginx-only]
set -euo pipefail
ROLE="${1:?ระบุ hostname ของ gateway เช่น gw-1 หรือ gw-2}"
MODE="${2:-full}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../inventory.env
source "$DIR/inventory.env"
# shellcheck disable=SC1091
[ -f "$DIR/secrets.env" ] && source "$DIR/secrets.env"

# กันพิมพ์ชื่อผิดเครื่อง (เช่นรัน erp-gw-01 บน erp-gw-02) → keepalived ได้ IP/priority สลับกัน
if [ "$(hostname)" != "$ROLE" ]; then
  echo "เครื่องนี้ชื่อ $(hostname) แต่สั่ง $ROLE — ใช้: sudo $0 $(hostname)" >&2; exit 1
fi

if [ "$ROLE" = "$GW_MASTER_HOST" ]; then
  SELF_IP=$GW_MASTER_IP; PEER_IP=$GW_BACKUP_IP; PRIORITY=110
elif [ "$ROLE" = "$GW_BACKUP_HOST" ]; then
  SELF_IP=$GW_BACKUP_IP; PEER_IP=$GW_MASTER_IP; PRIORITY=100
else
  echo "ROLE ต้องเป็น $GW_MASTER_HOST หรือ $GW_BACKUP_HOST" >&2; exit 1
fi
export ROLE SELF_IP PEER_IP PRIORITY VIP IFACE NET_PREFIX SVC1_IP SVC2_IP LEGACY_IP ZBX_HOST

apply_nginx() {
  rm -f /etc/nginx/sites-enabled/default
  # server_tokens มีใน nginx.conf ของ Ubuntu อยู่แล้ว (บางเวอร์ชัน comment ไว้) → เปิดที่นั่นจุดเดียว
  if grep -qE '^\s*#?\s*server_tokens\s' /etc/nginx/nginx.conf; then
    sed -i -E 's/^(\s*)#?\s*server_tokens\s+\w+;/\1server_tokens off;/' /etc/nginx/nginx.conf
  else
    sed -i -E 's/^(\s*http\s*\{)/\1\n\tserver_tokens off;/' /etc/nginx/nginx.conf
  fi
  mkdir -p /etc/nginx/infra /etc/nginx/ssl
  if [ ! -s /etc/nginx/ssl/star_nisolution_co_th.key ]; then
    echo "ยังไม่มี wildcard cert: copy ไฟล์ไปที่ /etc/nginx/ssl ก่อน (ดู docs/runbook.md ข้อ 4)" >&2
    exit 1
  fi
  chmod 600 /etc/nginx/ssl/*.key
  cp "$DIR"/gateway/nginx/infra/*.conf  /etc/nginx/infra/
  cp "$DIR"/gateway/nginx/conf.d/*.conf /etc/nginx/conf.d/
  # shellcheck disable=SC2016
  envsubst '$SVC1_IP $SVC2_IP $LEGACY_IP $ZBX_HOST' \
    < "$DIR/gateway/nginx/upstreams.conf.tpl" > /etc/nginx/conf.d/00-upstreams.conf
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
}

if [ "$MODE" = "--nginx-only" ]; then apply_nginx; exit 0; fi

export VRRP_PASS="${VRRP_PASS:?ยังไม่ได้สร้าง secrets.env}"
apt-get -y install nginx keepalived
apply_nginx

# shellcheck disable=SC2016
envsubst '$ROLE $IFACE $PRIORITY $SELF_IP $PEER_IP $VRRP_PASS $VIP $NET_PREFIX' \
  < "$DIR/gateway/keepalived/keepalived.conf.tpl" > /etc/keepalived/keepalived.conf
chmod 640 /etc/keepalived/keepalived.conf
install -m 755 "$DIR/gateway/keepalived/gw-notify.sh" /usr/local/bin/gw-notify.sh
systemctl enable keepalived
systemctl restart keepalived

ufw allow 80/tcp
ufw allow 443/tcp
# VRRP = IP protocol 112 ต้องใส่ผ่าน before.rules
# ลบกฎเดิมก่อนเสมอ (รันซ้ำได้ และแก้กรณีเคยใส่ PEER_IP ผิด)
sed -i '/--comment vrrp-peer/d' /etc/ufw/before.rules
sed -i "/^# End required lines/a -A ufw-before-input -p 112 -s $PEER_IP -m comment --comment vrrp-peer -j ACCEPT" \
  /etc/ufw/before.rules
ufw reload

echo "เสร็จ: ip -br addr show $IFACE  (เครื่องที่ถือ VIP จะเห็น $VIP)"
echo "เช็ก: curl -s http://127.0.0.1:8081/healthz   ·   grep vrrp-peer /etc/ufw/before.rules  (ต้องเป็น $PEER_IP)"
