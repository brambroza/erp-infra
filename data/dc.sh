#!/usr/bin/env bash
# docker compose ของ vm-data-4 — ใช้ไฟล์จาก repo + รหัสผ่านจาก /opt/data/.env
# ตัวอย่าง: data/dc.sh ps | data/dc.sh up -d | data/dc.sh logs -f mssql | data/dc.sh pull redis
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
exec docker compose -f "$DIR/compose.yml" --env-file /opt/data/.env "$@"
