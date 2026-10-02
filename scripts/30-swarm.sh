#!/usr/bin/env bash
# vm-service-1: sudo ./30-swarm.sh init
# vm-service-2: sudo ./30-swarm.sh join <worker-token>
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../inventory.env
source "$DIR/inventory.env"

apt-get -y install nfs-common

for ip in "$SVC1_IP" "$SVC2_IP"; do
  ufw allow from "$ip" to any port 2377,7946 proto tcp
  ufw allow from "$ip" to any port 7946,4789 proto udp
done
for ip in "$GW_MASTER_IP" "$GW_BACKUP_IP"; do
  ufw allow from "$ip" to any port 8284,6334,6344,6335 proto tcp
done
ufw allow from "$JENKINS_IP" to any port 22 proto tcp      # Jenkins ssh deploy

case "${1:-}" in
  init)
    docker swarm init --advertise-addr "$SVC1_IP"
    docker node update --label-add role=app "$(hostname)"
    # user สำหรับ Jenkins deploy
    id deploy >/dev/null 2>&1 || useradd -m -s /bin/bash -G docker deploy
    chown -R deploy:deploy "$DIR/stacks/erp"     # ให้ Jenkins แก้ versions.env และ deploy ได้
    echo "worker token:"
    docker swarm join-token -q worker
    ;;
  join)
    docker swarm join --token "${2:?ระบุ worker token}" "$SVC1_IP:2377"
    echo "ต่อไปบน $SVC1_HOST รัน: docker node update --label-add role=app $SVC2_HOST"
    ;;
  *)
    echo "ใช้: $0 init | join <token>" >&2; exit 1 ;;
esac
