#!/usr/bin/env bash
# erp-ci-01: Jenkins LTS + docker cli (build image ผ่าน docker socket ของเครื่อง)
# ใช้: sudo ./40-jenkins.sh   (หลัง 00-common.sh erp-ci-01 --docker)
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../inventory.env
source "$DIR/inventory.env"

mkdir -p /srv/jenkins_home
chown 1000:1000 /srv/jenkins_home          # uid ของ user jenkins ใน image

"$DIR/jenkins/dc.sh" up -d --build

for net in $ADMIN_NET; do ufw allow from "$net" to any port 8110 proto tcp; done
echo "Jenkins: http://$JENKINS_IP:8110"
echo "รหัสเริ่มต้น (ถ้าเป็นการติดตั้งใหม่): sudo cat /srv/jenkins_home/secrets/initialAdminPassword"
