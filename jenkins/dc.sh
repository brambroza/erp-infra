#!/usr/bin/env bash
# docker compose ของ erp-ci-01 — ใช้ไฟล์จาก repo + ค่าจาก inventory.env
# ตัวอย่าง: jenkins/dc.sh ps | jenkins/dc.sh up -d --build | jenkins/dc.sh logs -f
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../inventory.env
source "$DIR/../inventory.env"
JENKINS_IP_BIND="$JENKINS_IP"
DOCKER_GID="$(getent group docker | cut -d: -f3)"
export JENKINS_IP_BIND DOCKER_GID
exec docker compose -f "$DIR/compose.yml" "$@"
