#!/usr/bin/env bash
# สร้าง/อัปเดต login ของแอป (ค่าเริ่มต้น erp_app) ให้ใช้แทน sa
#   ได้:   อ่าน / เพิ่ม / แก้ / ลบ ข้อมูล, EXEC proc และ function ทุกตัว, อ่าน metadata (VIEW DEFINITION)
#   ไม่ได้: CREATE / ALTER / DROP table, view, proc, function, schema, user — และทำอะไรนอก DB นี้ไม่ได้
# รันซ้ำได้ทุกเมื่อ (idempotent) — ต้องรันซ้ำหลัง RESTORE ทุกครั้ง เพราะ DB จาก backup ไม่มี user นี้
# ใช้:  sudo data/mssql-app-user.sh                 (DB จาก MSSQL_BACKUP_DBS ใน /opt/data/.env)
#       sudo data/mssql-app-user.sh GoAlongDatabase
# รหัสผ่าน: ERP_APP_PASSWORD ใน /opt/data/.env (ถ้าไม่มี script จะสร้างและบันทึกให้)
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
ENV=/opt/data/.env
set -a; source "$ENV"; set +a

APP_LOGIN="${ERP_APP_LOGIN:-erp_app}"
DBS="${1:-$MSSQL_BACKUP_DBS}"

if [ -z "${ERP_APP_PASSWORD:-}" ]; then
  ERP_APP_PASSWORD="App-$(openssl rand -hex 12)-Aa1!"
  if grep -q '^ERP_APP_PASSWORD=' "$ENV"; then
    sed -i "s|^ERP_APP_PASSWORD=.*|ERP_APP_PASSWORD=$ERP_APP_PASSWORD|" "$ENV"
  else
    printf '\n# login ของแอป (สร้างโดย mssql-app-user.sh)\nERP_APP_LOGIN=%s\nERP_APP_PASSWORD=%s\n' "$APP_LOGIN" "$ERP_APP_PASSWORD" >> "$ENV"
  fi
  echo "สร้างรหัสผ่านใหม่และบันทึกใน $ENV แล้ว (ดูด้วย: sudo grep ERP_APP $ENV)"
fi
case "$APP_LOGIN$ERP_APP_PASSWORD" in *"'"*|*"]"*) echo "ห้ามมี ' หรือ ] ในชื่อ/รหัสผ่าน" >&2; exit 1;; esac

sql() {  # sql <db> <query>
  "$DIR/dc.sh" exec -T -e SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" mssql \
    /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -W -d "$1" -Q "$2"
}

# ---- ระดับ server: login ----
sql master "
SET NOCOUNT ON;
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$APP_LOGIN')
  CREATE LOGIN [$APP_LOGIN] WITH PASSWORD = N'$ERP_APP_PASSWORD', CHECK_POLICY = ON, CHECK_EXPIRATION = OFF;
ELSE
  ALTER LOGIN [$APP_LOGIN] WITH PASSWORD = N'$ERP_APP_PASSWORD';
ALTER LOGIN [$APP_LOGIN] ENABLE;"

for db in $DBS; do
  echo "== $db"
  sql "$db" "
SET NOCOUNT ON;
-- user ค้างจาก backup (orphan: SID ไม่ตรงกับ login บนเครื่องนี้) → ผูกใหม่
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$APP_LOGIN')
  ALTER USER [$APP_LOGIN] WITH LOGIN = [$APP_LOGIN], DEFAULT_SCHEMA = dbo;
ELSE
  CREATE USER [$APP_LOGIN] FOR LOGIN [$APP_LOGIN] WITH DEFAULT_SCHEMA = dbo;

-- ถอดสิทธิ์สูงออก (กรณีเคยใส่ไว้)
IF IS_ROLEMEMBER('db_owner',     N'$APP_LOGIN') = 1 ALTER ROLE db_owner     DROP MEMBER [$APP_LOGIN];
IF IS_ROLEMEMBER('db_ddladmin',  N'$APP_LOGIN') = 1 ALTER ROLE db_ddladmin  DROP MEMBER [$APP_LOGIN];
IF IS_ROLEMEMBER('db_securityadmin', N'$APP_LOGIN') = 1 ALTER ROLE db_securityadmin DROP MEMBER [$APP_LOGIN];

-- ข้อมูล: อ่าน/เพิ่ม/แก้/ลบ ทุกตาราง
ALTER ROLE db_datareader ADD MEMBER [$APP_LOGIN];
ALTER ROLE db_datawriter ADD MEMBER [$APP_LOGIN];

-- เรียก proc / scalar function / table type ได้ทุกตัว รวมตัวที่สร้างทีหลัง
GRANT EXECUTE TO [$APP_LOGIN];
-- อ่านโครงสร้าง (Dapper/EF/DeriveParameters ใช้) — อ่านอย่างเดียว ไม่ใช่สิทธิ์แก้
GRANT VIEW DEFINITION TO [$APP_LOGIN];

SELECT r.name AS role FROM sys.database_role_members m
JOIN sys.database_principals r ON r.principal_id = m.role_principal_id
JOIN sys.database_principals u ON u.principal_id = m.member_principal_id
WHERE u.name = N'$APP_LOGIN';
SELECT permission_name, state_desc FROM sys.database_permissions
WHERE grantee_principal_id = USER_ID(N'$APP_LOGIN') AND class = 0;"

  # proc/function ที่มีคำสั่งซึ่งต้องใช้สิทธิ์เกินที่ให้ไว้ → จะ error เมื่อแอปเรียกด้วย erp_app
  #   TRUNCATE / SET IDENTITY_INSERT ต้องมี ALTER บนตาราง, CREATE|ALTER|DROP TABLE (ที่ไม่ใช่ #temp) ต้องมีสิทธิ์ DDL
  #   ผลเป็นการค้นข้อความแบบหยาบ — 'DDL?' อาจเป็น #temp table ให้เปิดดูก่อนตัดสิน
  echo "-- proc/function ที่ควรตรวจ (ถ้าว่าง = ใช้สิทธิ์ชุดนี้ได้ทั้งหมด)"
  sql "$db" "
SET NOCOUNT ON;
SELECT OBJECT_SCHEMA_NAME(m.object_id) + '.' + OBJECT_NAME(m.object_id) AS module,
       CONCAT_WS(',',
         CASE WHEN m.definition LIKE '%TRUNCATE%TABLE%'          THEN 'TRUNCATE' END,
         CASE WHEN m.definition LIKE '%IDENTITY[_]INSERT%'        THEN 'IDENTITY_INSERT' END,
         CASE WHEN m.definition LIKE '%CREATE%TABLE [^#]%'
                OR m.definition LIKE '%DROP%TABLE [^#]%'
                OR m.definition LIKE '%ALTER%TABLE%'              THEN 'DDL?' END) AS uses
FROM sys.sql_modules m
WHERE m.definition LIKE '%TRUNCATE%TABLE%' OR m.definition LIKE '%IDENTITY[_]INSERT%'
   OR m.definition LIKE '%ALTER%TABLE%' OR m.definition LIKE '%CREATE%TABLE [^#]%'
   OR m.definition LIKE '%DROP%TABLE [^#]%'
ORDER BY module;"
done
echo "เสร็จ: $APP_LOGIN ใช้ได้กับ $DBS"
