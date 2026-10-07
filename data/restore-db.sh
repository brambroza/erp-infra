#!/usr/bin/env bash
# restore DB จากไฟล์ .bak ทับ DB บน erp-db-01 (ใช้วัน cutover กับ backup จากเครื่องเดิม หรือซ้อม restore)
#
#   sudo /opt/erp-infra/data/restore-db.sh /srv/mssql/backup/<ไฟล์>.bak [ชื่อ DB]
#
# ทำให้: ตรวจไฟล์ (VERIFYONLY) → map ไฟล์ข้อมูล/log ไปที่ path ของ DB เดิมบนเครื่องนี้ → เตะ connection ที่ค้าง
#        → RESTORE ... WITH REPLACE → ผูก login erp_app ใหม่ (mssql-app-user.sh) → นับตาราง/แถวให้เทียบกับต้นทาง
# ควร scale erp_erpapi / erp_chat-api เป็น 0 ก่อน (แอปจะได้ไม่ต่อเข้ามาระหว่าง restore)
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
set -a; source /opt/data/.env; set +a
die() { echo "$*" >&2; exit 1; }

BAK="${1:?ใช้: $0 /srv/mssql/backup/<ไฟล์>.bak [ชื่อ DB]}"
DB="${2:-${MSSQL_BACKUP_DBS%% *}}"
[[ "$DB" =~ ^[A-Za-z0-9_]+$ ]] || die "ชื่อ DB ไม่ถูกต้อง: $DB"
case "$BAK" in /srv/mssql/backup/*) ;; *) die "ไฟล์ต้องอยู่ใน /srv/mssql/backup/ (container เห็นเป็น /var/opt/mssql/backup/)";; esac
[ -f "$BAK" ] || die "ไม่พบไฟล์ $BAK"
B="/var/opt/mssql/backup/${BAK#/srv/mssql/backup/}"
[[ "$B" =~ ^[A-Za-z0-9_./-]+$ ]] || die "ชื่อไฟล์มีอักขระพิเศษ — เปลี่ยนชื่อก่อน"
chown 10001:0 "$BAK"   # SQL Server ใน container รันเป็น uid 10001

sql() {
  "$DIR/dc.sh" exec -T -e SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" mssql \
    /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -h -1 -W -s '|' -Q "$1"
}

echo "[1/5] ตรวจไฟล์ backup"
sql "RESTORE VERIFYONLY FROM DISK='$B'"

echo "[2/5] map ไฟล์ข้อมูล / log"
mapfile -t SRC < <(sql "SET NOCOUNT ON; RESTORE FILELISTONLY FROM DISK='$B'" | awk -F'|' 'NF>3 {print $3"|"$1}')
mapfile -t CUR < <(sql "SET NOCOUNT ON; SELECT CASE type WHEN 1 THEN 'L' ELSE 'D' END + '|' + physical_name FROM sys.master_files WHERE database_id = DB_ID('$DB') ORDER BY file_id")
[ "${#SRC[@]}" -gt 0 ] || die "อ่านรายการไฟล์ใน backup ไม่ได้"
MOVES=""; nd=0; nl=0
for row in "${SRC[@]}"; do
  t=${row%%|*}; logical=${row#*|}
  case "$logical" in *"'"*) die "ชื่อ logical file มี ' : $logical";; esac
  case "$t" in
    D) nd=$((nd+1)); want=$nd; ext=$([ $nd = 1 ] && echo mdf || echo ndf); def="/var/opt/mssql/data/${DB}$([ $nd = 1 ] || echo "_$nd").$ext" ;;
    L) nl=$((nl+1)); want=$nl; def="/var/opt/mssql/data/${DB}_log$([ $nl = 1 ] || echo "_$nl").ldf" ;;
    *) die "backup มีไฟล์ชนิด $t ($logical) — script นี้รองรับแค่ data/log" ;;
  esac
  # ใช้ path ของ DB เดิมบนเครื่องนี้ (ตัวที่ i ของชนิดเดียวกัน) ถ้ามี ไม่งั้นใช้ชื่อมาตรฐาน
  path=$(printf '%s\n' "${CUR[@]}" | awk -F'|' -v t="$t" -v n="$want" '$1==t && ++c==n {print $2}')
  path=${path:-$def}
  echo "  $t $logical → $path"
  MOVES+=", MOVE N'$logical' TO N'$path'"
done

echo "[3/5] เตะ connection ที่ค้างแล้ว restore $DB"
trap 'sql "IF DB_ID('"'$DB'"') IS NOT NULL ALTER DATABASE [$DB] SET MULTI_USER" >/dev/null 2>&1 || true' EXIT
sql "IF DB_ID('$DB') IS NOT NULL ALTER DATABASE [$DB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE"
sql "RESTORE DATABASE [$DB] FROM DISK='$B' WITH REPLACE, RECOVERY, STATS=25$MOVES"
sql "ALTER DATABASE [$DB] SET MULTI_USER"
trap - EXIT

echo "[4/5] ผูก login ของแอปใหม่"
"$DIR/mssql-app-user.sh" "$DB" >/dev/null
echo "  erp_app ใช้ได้กับ $DB แล้ว"

echo "[5/5] สรุป (เอาไปเทียบกับเครื่องเดิม)"
sql "SET NOCOUNT ON; USE [$DB];
SELECT 'tables=' + CAST(COUNT(DISTINCT p.object_id) AS varchar) + ' rows=' + CAST(SUM(p.rows) AS varchar)
FROM sys.partitions p JOIN sys.tables t ON t.object_id = p.object_id WHERE p.index_id IN (0,1);
SELECT 'state=' + state_desc + ' user_access=' + user_access_desc + ' compat=' + CAST(compatibility_level AS varchar)
FROM sys.databases WHERE name = '$DB';"
echo "restore $DB จาก $(basename "$BAK") เสร็จ"
