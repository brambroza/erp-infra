#!/usr/bin/env bash
# เก็บข้อมูลเครื่องเดิมก่อนย้ายระบบ — อ่านอย่างเดียว ไม่แก้อะไรบนเครื่อง
# ใช้:  sudo ./00-audit-legacy.sh
#       sudo SA_PASS='รหัส sa' ./00-audit-legacy.sh      (ถ้าต้องการขนาด DB และเวอร์ชัน SQL Server ด้วย)
# ผลลัพธ์: /root/legacy-audit-<วันที่>.tar.gz  มี env และรหัสผ่านอยู่ข้างใน ห้าม commit ห้ามส่งต่อ
set -uo pipefail

OUT="/root/legacy-audit-$(date +%F_%H%M)"
mkdir -p "$OUT"
chmod 700 "$OUT"
cd "$OUT" || exit 1

run() {  # run <ไฟล์ผลลัพธ์> <คำสั่ง...>  — คำสั่งไหนพังก็เก็บ error ไว้แล้วไปต่อ
  local f="$1"; shift
  { echo "\$ $*"; "$@"; } > "$f" 2>&1 || echo "(exit $?)" >> "$f"
}

echo "[1/7] เครื่อง"
run host.txt        bash -c 'hostnamectl; echo; ip -br addr; echo; ip route; echo; nproc; free -h; echo; df -h; echo; lsblk'
run listen.txt      ss -lntup
run cron.txt        bash -c 'crontab -l; ls -la /etc/cron.d; cat /etc/cron.d/* 2>/dev/null'
run ufw.txt         bash -c 'ufw status verbose 2>/dev/null || iptables -S'

echo "[2/7] บริการที่ไม่ได้อยู่ใน docker (3030, 5678, 10053)"
run legacy-ports.txt bash -c "ss -lntp | grep -E ':(3030|5678|10053)\b'; echo; systemctl list-units --type=service --state=running --no-pager; echo; command -v pm2 >/dev/null && pm2 ls"

echo "[3/7] nginx เดิม"
run nginx.txt       nginx -T
run ssl.txt         bash -c 'ls -la /etc/nginx/ssl; for c in /etc/nginx/ssl/*.crt; do echo "== $c"; openssl x509 -in "$c" -noout -subject -enddate 2>/dev/null; done'

echo "[4/7] docker"
run docker-ps.txt     docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
run docker-images.txt docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}\t{{.CreatedSince}}'
run docker-stats.txt  docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}'
run docker-df.txt     docker system df -v
mkdir -p inspect env
for c in $(docker ps -a --format '{{.Names}}'); do
  docker inspect "$c" > "inspect/$c.json" 2>&1
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c" > "env/$c.env" 2>&1
done
run mounts.txt bash -c "for c in \$(docker ps -a --format '{{.Names}}'); do echo \"== \$c\"; docker inspect -f '{{range .Mounts}}{{.Type}} {{.Source}} -> {{.Destination}}{{println}}{{end}}' \"\$c\"; done"
run volume-sizes.txt bash -c "for c in \$(docker ps -a --format '{{.Names}}'); do for s in \$(docker inspect -f '{{range .Mounts}}{{.Source}} {{end}}' \"\$c\"); do du -sh \"\$s\" 2>/dev/null | sed \"s#^#\$c  #\"; done; done"
run image-of-each.txt bash -c "docker ps -a --format '{{.Names}} {{.Image}}' | while read -r n i; do echo \"\$n  \$i  \$(docker inspect -f '{{.Image}}' \"\$n\")  repotags=\$(docker image inspect -f '{{.RepoTags}}' \"\$i\" 2>/dev/null)\"; done"

echo "[5/7] เวอร์ชันของ data service"
run redis.txt    bash -c 'docker exec redis-server redis-server --version; echo -n "ไม่ใส่รหัสแล้วเข้าได้หรือไม่ (PONG = ไม่มีรหัส): "; docker exec redis-server redis-cli PING 2>&1 | head -1; docker exec redis-server redis-cli INFO memory | grep -E "used_memory_human|maxmemory_human"'
run rabbitmq.txt bash -c 'docker exec rabbitmq rabbitmq-diagnostics server_version; docker exec rabbitmq rabbitmqctl list_queues name messages consumers'
run postgres.txt bash -c "docker ps --format '{{.Names}} {{.Image}}' | grep -i postgres | while read -r n _; do docker exec \"\$n\" psql -U postgres -c '\\l'; done"

echo "[6/7] SQL Server"
SQLCMD=""
for p in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd; do
  docker exec sqlserverhighperf test -x "$p" 2>/dev/null && { SQLCMD="$p"; break; }
done
if [ -n "${SA_PASS:-}" ] && [ -n "$SQLCMD" ]; then
  Q="SET NOCOUNT ON;
SELECT @@VERSION;
SELECT SERVERPROPERTY('Edition') AS edition, SERVERPROPERTY('ProductLevel') AS level, SERVERPROPERTY('ProductUpdateLevel') AS cu;
SELECT DB_NAME(database_id) AS db, type_desc, name AS logical_name, physical_name, size*8/1024 AS size_mb FROM sys.master_files ORDER BY db;
SELECT name, type_desc FROM sys.server_principals WHERE type IN ('S','U') AND name NOT LIKE '##%';"
  run mssql.txt docker exec -e SQLCMDPASSWORD="$SA_PASS" sqlserverhighperf "$SQLCMD" -S localhost -U sa -C -W -Q "$Q"
else
  echo "ข้าม: ไม่ได้ตั้ง SA_PASS หรือไม่พบ sqlcmd ใน container" > mssql.txt
fi

echo "[7/7] Jenkins"
run jenkins.txt bash -c "J=\$(docker ps --format '{{.Names}} {{.Image}}' | awk '/jenkins/{print \$1; exit}'); echo container=\$J; docker exec \"\$J\" bash -c 'cat /var/jenkins_home/config.xml | grep -m1 -i version; ls /var/jenkins_home/jobs; du -sh /var/jenkins_home'"

cd /root && tar czf "$OUT.tar.gz" "$(basename "$OUT")" && chmod 600 "$OUT.tar.gz"
echo
echo "เสร็จ: $OUT.tar.gz"
echo "ไฟล์นี้มี env และรหัสผ่านของทุก container — เก็บไว้ในเครื่องเท่านั้น"
echo "ส่งให้ทีม/Claude ได้ (ไม่มีรหัสผ่าน):"
echo "  host.txt listen.txt ufw.txt legacy-ports.txt nginx.txt ssl.txt"
echo "  docker-ps.txt docker-images.txt docker-stats.txt docker-df.txt image-of-each.txt"
echo "  mounts.txt volume-sizes.txt redis.txt rabbitmq.txt postgres.txt mssql.txt jenkins.txt"
echo "ห้ามส่ง: env/ inspect/  ·  cron.txt ให้เปิดดูก่อน (บางคำสั่งอาจมีรหัสผ่านอยู่ในบรรทัด)"
echo
echo "รวมไฟล์ที่ส่งได้ไว้ที่ /tmp/audit-safe.tgz:"
echo "  sudo tar czf /tmp/audit-safe.tgz -C $OUT host.txt listen.txt ufw.txt legacy-ports.txt nginx.txt ssl.txt \\"
echo "    docker-ps.txt docker-images.txt docker-stats.txt docker-df.txt image-of-each.txt mounts.txt volume-sizes.txt \\"
echo "    redis.txt rabbitmq.txt postgres.txt mssql.txt jenkins.txt && sudo chown \$SUDO_USER /tmp/audit-safe.tgz"
