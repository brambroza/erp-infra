#!/usr/bin/env bash
# เตรียมเครื่องทุกตัว
# ใช้: sudo ./00-common.sh <hostname> [--docker]
set -euo pipefail
HOST="${1:?ระบุ hostname เช่น erp-gw-01, erp-app-01}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../inventory.env
source "$DIR/inventory.env"

hostnamectl set-hostname "$HOST"
timedatectl set-timezone Asia/Bangkok

sed -i '/# erp-infra-begin/,/# erp-infra-end/d' /etc/hosts
cat >> /etc/hosts <<EOF
# erp-infra-begin
$GW_MASTER_IP $GW_MASTER_HOST
$GW_BACKUP_IP $GW_BACKUP_HOST
$SVC1_IP $SVC1_HOST
$SVC2_IP $SVC2_HOST
$DATA_IP $DATA_HOST
$JENKINS_IP $JENKINS_HOST
# erp-infra-end
EOF

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y upgrade
apt-get -y install curl ca-certificates ufw chrony jq rsync gettext-base \
                   unattended-upgrades zabbix-agent

cat > /etc/sysctl.d/90-erp-infra.conf <<'EOF'
net.core.somaxconn = 4096
net.ipv4.ip_local_port_range = 10240 65000
net.ipv4.tcp_tw_reuse = 1
fs.file-max = 1000000
vm.swappiness = 10
EOF
sysctl --system >/dev/null

# zabbix agent บนตัวเครื่อง
sed -i "s/^Server=.*/Server=$ZABBIX_SERVER/; s/^ServerActive=.*/ServerActive=$ZABBIX_SERVER/; s/^Hostname=.*/Hostname=$HOST/" \
  /etc/zabbix/zabbix_agentd.conf
systemctl enable zabbix-agent
systemctl restart zabbix-agent

ufw default deny incoming
ufw default allow outgoing
# ADMIN_NET รับได้หลายวง คั่นด้วยช่องว่าง เช่น "192.168.88.0/24 10.212.134.0/24"
for net in $ADMIN_NET; do
  ufw allow from "$net" to any port 22 proto tcp
done
# กันพลาด: ถ้ามี SSH session ที่ต่ออยู่จาก IP นอก ADMIN_NET ให้หยุดก่อนเปิด firewall (ไม่งั้นโดนตัดทันที)
peers=$(ss -Htn state established '( sport = :22 )' | awk '{print $NF}')
if ! python3 - "$ADMIN_NET" $peers <<'PY'
import ipaddress, sys
nets = [ipaddress.ip_network(n, strict=False) for n in sys.argv[1].split()]
bad = []
for p in sys.argv[2:]:
    host = p.rsplit(":", 1)[0].strip("[]")
    ip = ipaddress.ip_address(host)
    if getattr(ip, "ipv4_mapped", None):
        ip = ip.ipv4_mapped
    if not any(ip in n for n in nets):
        bad.append(str(ip))
if bad:
    print("SSH จาก " + ", ".join(sorted(set(bad))) + " ไม่อยู่ใน ADMIN_NET", file=sys.stderr)
    sys.exit(1)
PY
then
  echo "หยุด: ถ้าเปิด firewall ตอนนี้ SSH ที่ใช้อยู่จะโดนตัด — เพิ่มวง IP นั้นใน ADMIN_NET (inventory.env) ก่อน" >&2
  exit 1
fi
ufw allow from "$ZABBIX_SERVER" to any port 10050 proto tcp
ufw --force enable

if [ "${2:-}" = "--docker" ]; then
  command -v docker >/dev/null || curl -fsSL https://get.docker.com | sh
  cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "5" }
}
EOF
  systemctl restart docker
  # ลบ image เก่าที่ไม่ได้ใช้เกิน 7 วัน ทุกวันอาทิตย์
  echo '30 3 * * 0 root docker image prune -af --filter "until=168h" >/dev/null 2>&1' > /etc/cron.d/docker-prune
fi

echo "00-common: $HOST เสร็จ"
