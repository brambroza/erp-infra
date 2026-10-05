#!/usr/bin/env bash
# ค่าที่ Zabbix agent ถาม (เรียกผ่าน UserParameter ใน erp-infra.conf) — ติดตั้งโดย scripts/50-zabbix.sh
# อ่านอย่างเดียว · คำสั่ง docker ถูกเรียกผ่าน sudo (sudoers อนุญาตเฉพาะ script นี้)
VIP="__VIP__"
STACK=erp
services() { docker service ls --filter "label=com.docker.stack.namespace=$STACK" --format '{{.Name}}'; }

case "${1:-}" in
  # ---------- gateway ----------
  vip)        # 1 = เครื่องนี้ถือ VIP อยู่, 0 = ไม่ได้ถือ
    ip -o -4 addr show | grep -q " ${VIP}/" && echo 1 || echo 0 ;;
  certdays)   # จำนวนวันก่อน cert หมดอายุ อ่านจาก nginx ตรง ๆ (-1 = อ่านไม่ได้)
    end=$(echo | timeout 5 openssl s_client -connect 127.0.0.1:443 -servername "${2:-erp.nisolution.co.th}" 2>/dev/null \
          | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    if [ -n "$end" ]; then echo $(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 )); else echo -1; fi ;;

  # ---------- ทุกเครื่องใน Swarm ----------
  node-containers)   # container ของ stack erp ที่รันอยู่บนเครื่องนี้
    docker ps -q --filter "label=com.docker.stack.namespace=$STACK" | wc -l ;;
  node-nfs)          # 1 = volume erp-files (NFS) ถูก mount อยู่บนเครื่องนี้
    grep -q ':/srv/nfs/erp-files ' /proc/mounts && echo 1 || echo 0 ;;

  # ---------- เฉพาะ manager ----------
  swarm-discovery)   # รายชื่อ service สำหรับ Zabbix LLD
    services | jq -cRn '{data: [inputs | select(length>0) | {"{#SVC}": .}]}' ;;
  swarm-missing)     # จำนวน replica ที่ขาด (desired - running) ของ service ที่ระบุ
    svc="${2:-}"
    [[ "$svc" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "ชื่อ service ไม่ถูกต้อง" >&2; exit 1; }
    rep=$(docker service ls --filter "name=$svc" --format '{{.Name}} {{.Replicas}}' | awk -v s="$svc" '$1==s {print $2}')
    [ -n "$rep" ] || { echo -1; exit 0; }
    run=${rep%%/*}; want=${rep#*/}; want=${want%% *}
    echo $(( want > run ? want - run : 0 )) ;;
  swarm-nodes-bad)   # node ที่ไม่ใช่ Ready + Active
    docker node ls --format '{{.Status}} {{.Availability}}' | grep -vc '^Ready Active$' || true ;;
  swarm-failed)      # task ที่ Failed / Rejected ภายใน ~1 ชั่วโมง (container ล้ม / healthcheck ไม่ผ่าน)
    n=0
    for s in $(services); do
      c=$(docker service ps "$s" --format '{{.CurrentState}}' | grep -E '^(Failed|Rejected)' | grep -Ec 'second|minute' || true)
      n=$((n + c))
    done
    echo "$n" ;;
  *) echo "ใช้: $0 vip|certdays|node-containers|node-nfs|swarm-discovery|swarm-missing <svc>|swarm-nodes-bad|swarm-failed" >&2; exit 1 ;;
esac
