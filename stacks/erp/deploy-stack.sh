#!/usr/bin/env bash
# deploy / อัปเดต stack "erp" — รันบน vm-service-1 (Swarm manager) เท่านั้น
set -euo pipefail
cd "$(dirname "$0")"

if grep -q 'CHANGE_ME' versions.env; then
  echo "versions.env ยังมี CHANGE_ME — ใส่ tag จริงก่อน" >&2; exit 1
fi
for f in erpapi.env chat-api.env ticker.env; do
  [ -f "$f" ] || { echo "ไม่พบ $f (copy จาก $f.example)" >&2; exit 1; }
done

set -a
# shellcheck disable=SC1091
source ../../inventory.env
# shellcheck disable=SC1091
source ./versions.env
set +a
# โหมด: STACK_MODE ใน versions.env (test = บล็อกข้อความออก, live = production)
# ไม่ได้ตั้ง = test เสมอ → Jenkins/คน deploy ก่อน cutover จะไม่ส่ง LINE/push หาลูกค้าจริงโดยไม่ตั้งใจ
# TEST=1 บังคับ test ได้ทุกเมื่อ
MODE="${STACK_MODE:-test}"
[ "${TEST:-0}" = 1 ] && MODE=test
FILES=(-c stack.yml)
case "$MODE" in
  live) echo "STACK_MODE=live: production — ส่ง LINE / push / อีเมลออกจริง" ;;
  test) FILES+=(-c stack.test.yml)
        echo "STACK_MODE=test: บล็อก LINE / Expo push / Facebook / Gmail (ตั้ง STACK_MODE=live ใน versions.env ตอน cutover)" ;;
  *)    echo "STACK_MODE ต้องเป็น test หรือ live (ได้ '$MODE')" >&2; exit 1 ;;
esac
docker stack deploy "${FILES[@]}" --with-registry-auth erp
