#!/usr/bin/env bash
# รอให้ service อัปเดตเสร็จ ถ้าโดน rollback หรือค้างให้ exit 1 (Jenkins จะ fail)
# ใช้: ./wait-converge.sh erp_erpapi [timeout_seconds]
set -euo pipefail
SVC="${1:?เช่น erp_erpapi}"
TIMEOUT="${2:-300}"
sleep 5
for ((i = 0; i < TIMEOUT; i += 5)); do
  state=$(docker service inspect "$SVC" \
    --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{else}}completed{{end}}')
  case "$state" in
    completed) echo "$SVC: อัปเดตเสร็จ"; exit 0 ;;
    rollback_completed|paused|rollback_paused) echo "$SVC: $state" >&2; exit 1 ;;
  esac
  sleep 5
done
echo "$SVC: เกินเวลา $TIMEOUT วินาที" >&2
exit 1
