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
docker stack deploy -c stack.yml --with-registry-auth erp
