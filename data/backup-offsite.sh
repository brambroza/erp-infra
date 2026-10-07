#!/usr/bin/env bash
# ส่ง backup DB ไปนอกเครื่องผ่าน FTP (เรียกต่อท้าย mssql-backup.sh ทุกคืน · รันมือได้เพื่อทดสอบ)
#
#   sudo /usr/local/bin/backup-offsite.sh          ส่งไฟล์ที่ยังไม่มีบน FTP + ลบไฟล์เก่าบน FTP
#   sudo /usr/local/bin/backup-offsite.sh --test   ทดสอบ login + เขียน/ลบไฟล์ทดสอบบน FTP เท่านั้น
#
# ขั้นตอน: .bak → gzip → (เข้ารหัส AES-256 ถ้าตั้ง BACKUP_ENC_PASS) → /srv/mssql/offsite/ → lftp mirror ขึ้น FTP
# - ส่งเฉพาะไฟล์ที่ยังไม่มีบนปลายทาง → คืนไหนล้ม คืนถัดไปส่งตามให้เอง
# - อัปโหลดเป็นชื่อชั่วคราวก่อนแล้วค่อย rename → ไฟล์ครึ่ง ๆ จะไม่ถูกนับว่าส่งแล้ว
# - ทุกไฟล์มี .sha256 คู่กัน ใช้ตรวจตอนกู้คืน
# - ส่งสำเร็จ → เขียนเวลาไว้ที่ /var/lib/erp-backup/offsite.ok (Zabbix อ่านค่านี้)
# ค่าตั้งทั้งหมดอยู่ใน /opt/data/.env (chmod 600) — ห้ามใส่รหัสผ่านใน repo
set -euo pipefail
set -a
# shellcheck disable=SC1091
source /opt/data/.env
set +a

: "${BACKUP_FTP_HOST:?ยังไม่ได้ตั้ง BACKUP_FTP_HOST ใน /opt/data/.env}"
: "${BACKUP_FTP_USER:?ยังไม่ได้ตั้ง BACKUP_FTP_USER}"
: "${BACKUP_FTP_PASS:?ยังไม่ได้ตั้ง BACKUP_FTP_PASS}"
PORT=${BACKUP_FTP_PORT:-21}
RDIR=${BACKUP_FTP_DIR:-/erp-backup}; RDIR=${RDIR%/}
KEEP=${BACKUP_FTP_KEEP_DAYS:-30}
TLS=${BACKUP_FTP_TLS:-auto}
SRC=/srv/mssql/backup
STAGE=/srv/mssql/offsite
STATE=/var/lib/erp-backup
command -v lftp >/dev/null || { echo "ไม่มี lftp — apt-get install -y lftp" >&2; exit 1; }
[[ "$KEEP" =~ ^[0-9]+$ ]] || { echo "BACKUP_FTP_KEEP_DAYS ต้องเป็นตัวเลข" >&2; exit 1; }

exec 9>/run/erp-backup-offsite.lock
flock -n 9 || { echo "มี backup-offsite อีกตัวรันอยู่" >&2; exit 1; }
mkdir -p "$STAGE" "$STATE"; chmod 700 "$STAGE"

# รหัสผ่านส่งผ่าน env (LFTP_PASSWORD + --env-password) ไม่โผล่ใน ps / log
export LFTP_PASSWORD="$BACKUP_FTP_PASS"
ftp() {
  local tls
  case "$TLS" in
    force) tls="set ftp:ssl-force yes; set ftp:ssl-protect-data yes; set ssl:verify-certificate ${BACKUP_FTP_VERIFY_CERT:-no};" ;;
    off)   tls="set ftp:ssl-allow no;" ;;
    *)     tls="set ftp:ssl-allow yes; set ssl:verify-certificate ${BACKUP_FTP_VERIFY_CERT:-no};" ;;
  esac
  lftp -c "set cmd:fail-exit yes; set net:timeout 30; set net:max-retries 3; set net:reconnect-interval-base 10;
           set ftp:passive-mode yes; set xfer:use-temp-file yes; set xfer:temp-file-name .part-*;
           $tls open -p $PORT -u '$BACKUP_FTP_USER' --env-password $BACKUP_FTP_HOST; $1"
}

if [ "${1:-}" = "--test" ]; then
  t=$(mktemp); echo "erp-db-01 offsite test $(date -Is)" > "$t"
  ftp "mkdir -p -f $RDIR/mssql; cd $RDIR/mssql; put $t -o .offsite-test; cls -1 .offsite-test; rm .offsite-test"
  rm -f "$t"
  echo "ทดสอบผ่าน: login ได้ เขียน/ลบไฟล์ใน $RDIR/mssql บน $BACKUP_FTP_HOST:$PORT ได้ (TLS=$TLS)"
  exit 0
fi

# 1) เตรียมไฟล์: บีบอัด (+เข้ารหัส) .bak ที่ยังไม่เคยเตรียม
for f in "$SRC"/*.bak; do
  [ -e "$f" ] || continue
  b=$(basename "$f")
  if [ -n "${BACKUP_ENC_PASS:-}" ]; then out="$STAGE/$b.gz.enc"; else out="$STAGE/$b.gz"; fi
  [ -s "$out" ] && continue
  if [ -n "${BACKUP_ENC_PASS:-}" ]; then
    gzip -c "$f" | openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass env:BACKUP_ENC_PASS > "$out.tmp"
  else
    gzip -c "$f" > "$out.tmp"
  fi
  mv "$out.tmp" "$out"
  (cd "$STAGE" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256")
  echo "$(date -Is) เตรียม $(basename "$out") ($(( $(stat -c %s "$out") / 1048576 )) MB)"
done
rm -f "$STAGE"/*.tmp
# ในเครื่องเก็บไฟล์เตรียมส่ง 7 วันเท่ากับ .bak
find "$STAGE" -type f -mtime +7 -delete

# 2) ส่งขึ้น FTP เฉพาะไฟล์ที่ยังไม่มี
ftp "mkdir -p -f $RDIR/mssql; mirror -R --only-missing --no-perms --no-symlinks --parallel=1 $STAGE/ $RDIR/mssql/"

# 3) ตรวจว่าไฟล์ล่าสุดขึ้นไปจริง
last=$(ls -t "$STAGE" | grep -v '\.sha256$' | head -1 || true)
if [ -n "$last" ]; then
  ftp "cls -1 $RDIR/mssql/$last $RDIR/mssql/$last.sha256" >/dev/null
fi

# 4) ลบไฟล์บน FTP ที่เก่ากว่า KEEP วัน (ดูจากวันที่ในชื่อไฟล์ เช่น GoAlongDatabase_2026-10-07_0100.bak.gz)
if [ "$KEEP" -gt 0 ]; then
  cutoff=$(date -d "-$KEEP days" +%F)
  old=$(ftp "cls -1 $RDIR/mssql/" | sed 's#.*/##' \
        | awk -v c="$cutoff" 'match($0, /_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4}\.bak/) { d=substr($0, RSTART+1, 10); if (d < c) print }')
  if [ -n "$old" ]; then
    cmds=""; while read -r n; do cmds+="rm $RDIR/mssql/$n; "; done <<< "$old"
    ftp "$cmds"
    echo "$(date -Is) ลบบน FTP $(wc -l <<< "$old") ไฟล์ (เก่ากว่า $cutoff)"
  fi
fi

# 5) (ไม่บังคับ) ไฟล์ upload ของ erpapi / chat-api — ไม่ได้เข้ารหัส เปิดเมื่อ FTP เป็น TLS หรืออยู่ในเครือข่ายที่ไว้ใจได้
if [ "${BACKUP_FTP_FILES:-0}" = 1 ]; then
  ftp "mkdir -p -f $RDIR/erp-files; mirror -R --only-newer --no-perms --no-symlinks --parallel=2 /srv/nfs/erp-files/ $RDIR/erp-files/"
fi

date +%s > "$STATE/offsite.ok"
echo "$(date -Is) offsite ok → $BACKUP_FTP_HOST:$PORT$RDIR (ล่าสุด: ${last:-ไม่มีไฟล์})"
