#!/usr/bin/env bash
# เตรียมเครื่องทุกตัว
# ใช้: sudo ./00-common.sh <hostname> [--docker]
set -euo pipefail
HOST="${1:?ระบุ hostname เช่น gw-1, vm-service-1}"
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
ufw allow from "$ADMIN_NET" to any port 22 proto tcp
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
