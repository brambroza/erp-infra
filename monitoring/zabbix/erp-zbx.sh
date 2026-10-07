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
  # ---------- erp-db-01: cron (root) เก็บทุกนาที → Zabbix อ่านไฟล์ (คำสั่ง sqlcmd / rabbitmq ช้าเกิน timeout ของ Zabbix) ----------
  db-collect)
    set -a; . /opt/data/.env; set +a
    out=/var/lib/erp-zbx/db.env; mkdir -p /var/lib/erp-zbx
    cid() { docker ps -q --filter label=com.docker.compose.project=data --filter "label=com.docker.compose.service=$1" | head -1; }
    M=$(cid mssql); R=$(cid redis); Q=$(cid rabbitmq)
    {
      echo "ts=$(date +%s)"
      findmnt -n /srv >/dev/null && echo srv_mounted=1 || echo srv_mounted=0
      f=$(ls -t /srv/mssql/backup/*.bak 2>/dev/null | head -1)
      if [ -n "$f" ]; then
        echo "backup_age_h=$(( ( $(date +%s) - $(stat -c %Y "$f") ) / 3600 ))"
        echo "backup_size_mb=$(( $(stat -c %s "$f") / 1048576 ))"
      else echo backup_age_h=-1; echo backup_size_mb=0; fi
      # ส่ง FTP สำเร็จล่าสุดกี่ชั่วโมงแล้ว (-2 = ไม่ได้ตั้ง FTP, -1 = ตั้งแล้วแต่ยังไม่เคยสำเร็จ)
      if [ -z "${BACKUP_FTP_HOST:-}" ]; then echo offsite_age_h=-2
      elif [ -s /var/lib/erp-backup/offsite.ok ]; then echo "offsite_age_h=$(( ( $(date +%s) - $(cat /var/lib/erp-backup/offsite.ok) ) / 3600 ))"
      else echo offsite_age_h=-1; fi
      for s in mssql redis rabbitmq; do
        echo "c_$s=$(docker ps -q --filter label=com.docker.compose.project=data --filter "label=com.docker.compose.service=$s" | wc -l)"
      done
      db=${MSSQL_BACKUP_DBS%% *}
      if [ -n "$M" ]; then
        r=$(timeout 20 docker exec -e SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" "$M" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -h -1 -W -s ' ' \
            -Q "SET NOCOUNT ON; SELECT CASE WHEN DATABASEPROPERTYEX('$db','Status')='ONLINE' THEN 1 ELSE 0 END, (SELECT ISNULL(SUM(CAST(size AS bigint))*8/1024,0) FROM sys.master_files WHERE database_id=DB_ID('$db') AND type=0)" 2>/dev/null \
            | tr -d '\r' | grep -E '^[01] [0-9]+$' | head -1)
        if [ -n "$r" ]; then echo "mssql_online=${r%% *}"; echo "mssql_data_mb=${r##* }"
        else echo mssql_online=0; echo mssql_data_mb=0; fi
      else echo mssql_online=0; echo mssql_data_mb=0; fi
      if [ -n "$R" ]; then
        [ "$(timeout 10 docker exec -e REDISCLI_AUTH="$REDIS_PASSWORD" "$R" redis-cli ping 2>/dev/null | tr -d '\r')" = PONG ] && echo redis_ping=1 || echo redis_ping=0
        timeout 10 docker exec -e REDISCLI_AUTH="$REDIS_PASSWORD" "$R" redis-cli info memory 2>/dev/null | tr -d '\r' \
          | awk -F: '/^used_memory:/{u=$2} /^maxmemory:/{m=$2} END{printf "redis_mem_pct=%d\n", (m>0 ? u*100/m : 0)}'
      else echo redis_ping=0; echo redis_mem_pct=0; fi
      if [ -n "$Q" ]; then
        timeout 20 docker exec "$Q" rabbitmq-diagnostics -q check_running >/dev/null 2>&1 && echo rabbit_ok=1 || echo rabbit_ok=0
        timeout 20 docker exec "$Q" rabbitmq-diagnostics -q check_local_alarms >/dev/null 2>&1 && echo rabbit_alarm=0 || echo rabbit_alarm=1
        mq=$(timeout 20 docker exec "$Q" rabbitmqctl list_queues -q --no-table-headers messages 2>/dev/null | tr -dc '0-9\n' | sort -n | tail -1)
        echo "rabbit_max_queue=${mq:-0}"
      else echo rabbit_ok=0; echo rabbit_alarm=0; echo rabbit_max_queue=0; fi
      systemctl is-active -q nfs-server && echo nfs_server=1 || echo nfs_server=0
      exportfs 2>/dev/null | grep -q '^/srv/nfs/erp-files' && echo nfs_export=1 || echo nfs_export=0
    } | awk -F= '!seen[$1]++' > "$out.tmp" && mv "$out.tmp" "$out"
    chmod 644 "$out" ;;
  db-get)            # อ่านค่าจากไฟล์ที่ db-collect เขียนไว้ (ไม่ต้องใช้ root)
    k="${2:-}"; [[ "$k" =~ ^[a-z_]+$ ]] || { echo "ชื่อค่าไม่ถูกต้อง" >&2; exit 1; }
    f=/var/lib/erp-zbx/db.env
    if [ "$k" = collect_age ]; then ts=$(grep -m1 '^ts=' "$f" 2>/dev/null | cut -d= -f2); echo $(( $(date +%s) - ${ts:-0} )); exit 0; fi
    grep -m1 "^$k=" "$f" 2>/dev/null | cut -d= -f2 ;;
  *) echo "ใช้: $0 vip|certdays|node-containers|node-nfs|swarm-discovery|swarm-missing <svc>|swarm-nodes-bad|swarm-failed|db-collect|db-get <key>" >&2; exit 1 ;;
esac
