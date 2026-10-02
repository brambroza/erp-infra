#!/usr/bin/env bash
# vm-jenkins: Jenkins LTS + docker cli (build image ผ่าน docker socket ของเครื่อง)
# ใช้: sudo ./40-jenkins.sh   (หลัง 00-common.sh vm-jenkins --docker)
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../inventory.env
source "$DIR/inventory.env"

mkdir -p /srv/jenkins_home
chown 1000:1000 /srv/jenkins_home          # uid ของ user jenkins ใน image

JENKINS_IP_BIND="$JENKINS_IP"
DOCKER_GID="$(getent group docker | cut -d: -f3)"
export JENKINS_IP_BIND DOCKER_GID
docker compose -f "$DIR/jenkins/compose.yml" up -d --build

ufw allow from "$ADMIN_NET" to any port 8110 proto tcp
echo "Jenkins: http://$JENKINS_IP:8110"
echo "รหัสเริ่มต้น (ถ้าเป็นการติดตั้งใหม่): sudo cat /srv/jenkins_home/secrets/initialAdminPassword"
