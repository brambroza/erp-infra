#!/usr/bin/env bash
# ดึง environment ของ container เดิมออกมาเป็นไฟล์ .env
# ใช้: ./export-env.sh go-crmapi24 > erpapi.env
# จากนั้นแก้ host ของ DB / Redis / RabbitMQ ให้ชี้ไป vm-data-4
set -euo pipefail
NAME="${1:?ระบุชื่อ container}"
docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$NAME" \
  | grep -v -E '^(PATH|HOSTNAME|HOME|DOTNET_VERSION|ASPNET_VERSION|NODE_VERSION|YARN_VERSION)=' \
  | sed '/^$/d'
