-- นับของใน GoAlongDatabase ที่ต้องแปลงถ้าย้ายไป MySQL (อ่านอย่างเดียว ไม่แก้อะไร)
-- รันบน erp-db-01:
--   sudo /opt/erp-infra/data/dc.sh exec -T -e SQLCMDPASSWORD="$(sudo grep -oP '^MSSQL_SA_PASSWORD=\K.*' /opt/data/.env)" mssql \
--     /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -W -d GoAlongDatabase -i /dev/stdin < /opt/erp-infra/data/mssql-inventory.sql
SET NOCOUNT ON;

PRINT '== 1. object ที่ต้องแปลง';
SELECT type_desc AS object_type, COUNT(*) AS n
FROM sys.objects WHERE is_ms_shipped = 0
GROUP BY type_desc ORDER BY n DESC;

PRINT '== 2. ขนาดโค้ด proc / function / trigger / view';
SELECT o.type_desc, COUNT(*) AS n,
       SUM(LEN(m.definition) - LEN(REPLACE(m.definition, CHAR(10), '')) + 1) AS total_lines,
       MAX(LEN(m.definition) - LEN(REPLACE(m.definition, CHAR(10), '')) + 1) AS max_lines
FROM sys.sql_modules m JOIN sys.objects o ON o.object_id = m.object_id
GROUP BY o.type_desc;

PRINT '== 3. proc ตามขนาด (บรรทัด) — ใช้ประเมินเวลา';
SELECT CASE WHEN l <= 30 THEN 'a. <=30' WHEN l <= 100 THEN 'b. 31-100' WHEN l <= 300 THEN 'c. 101-300' ELSE 'd. >300' END AS size, COUNT(*) AS n
FROM (SELECT LEN(m.definition) - LEN(REPLACE(m.definition, CHAR(10), '')) + 1 AS l
      FROM sys.sql_modules m JOIN sys.procedures p ON p.object_id = m.object_id) x
GROUP BY CASE WHEN l <= 30 THEN 'a. <=30' WHEN l <= 100 THEN 'b. 31-100' WHEN l <= 300 THEN 'c. 101-300' ELSE 'd. >300' END
ORDER BY size;

PRINT '== 4. feature ของ T-SQL ที่ MySQL ไม่มี / เขียนต่างกัน (จำนวน module ที่ใช้)';
SELECT
  SUM(CASE WHEN d LIKE '%#[a-z]%'              THEN 1 ELSE 0 END) AS temp_table,
  SUM(CASE WHEN d LIKE '%declare%@%table%(%'   THEN 1 ELSE 0 END) AS table_variable,
  SUM(CASE WHEN d LIKE '%cursor%'              THEN 1 ELSE 0 END) AS cursor_,
  SUM(CASE WHEN d LIKE '%begin try%'           THEN 1 ELSE 0 END) AS try_catch,
  SUM(CASE WHEN d LIKE '%raiserror%' OR d LIKE '%throw%' THEN 1 ELSE 0 END) AS raise_throw,
  SUM(CASE WHEN d LIKE '%sp_executesql%' OR d LIKE '%exec(%' OR d LIKE '%exec (%' THEN 1 ELSE 0 END) AS dynamic_sql,
  SUM(CASE WHEN d LIKE '%for xml%'             THEN 1 ELSE 0 END) AS for_xml,
  SUM(CASE WHEN d LIKE '%for json%'            THEN 1 ELSE 0 END) AS for_json,
  SUM(CASE WHEN d LIKE '%pivot%'               THEN 1 ELSE 0 END) AS pivot_,
  SUM(CASE WHEN d LIKE '%merge %'              THEN 1 ELSE 0 END) AS merge_,
  SUM(CASE WHEN d LIKE '%output inserted%' OR d LIKE '%output deleted%' THEN 1 ELSE 0 END) AS output_clause,
  SUM(CASE WHEN d LIKE '%string_agg%'          THEN 1 ELSE 0 END) AS string_agg,
  SUM(CASE WHEN d LIKE '%scope_identity%' OR d LIKE '%@@identity%' THEN 1 ELSE 0 END) AS identity_fn,
  SUM(CASE WHEN d LIKE '%@@rowcount%'          THEN 1 ELSE 0 END) AS rowcount_,
  SUM(CASE WHEN d LIKE '%newid()%'             THEN 1 ELSE 0 END) AS newid_,
  SUM(CASE WHEN d LIKE '%top %' OR d LIKE '%top(%' THEN 1 ELSE 0 END) AS top_,
  SUM(CASE WHEN d LIKE '%convert(%'            THEN 1 ELSE 0 END) AS convert_,
  SUM(CASE WHEN d LIKE '%exec %'               THEN 1 ELSE 0 END) AS calls_other_proc,
  SUM(CASE WHEN d LIKE '%nolock%'              THEN 1 ELSE 0 END) AS nolock_
FROM sys.sql_modules m
CROSS APPLY (SELECT LOWER(m.definition) AS d) x;

PRINT '== 5. ตารางที่ไม่มี primary key (InnoDB Cluster บังคับให้มีทุกตาราง)';
SELECT s.name + '.' + t.name AS table_without_pk
FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE OBJECTPROPERTY(t.object_id, 'TableHasPrimaryKey') = 0
ORDER BY 1;

PRINT '== 6. ชนิดข้อมูลที่ใช้';
SELECT ty.name AS data_type, COUNT(*) AS columns_
FROM sys.columns c
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
JOIN sys.tables t ON t.object_id = c.object_id
GROUP BY ty.name ORDER BY columns_ DESC;

PRINT '== 7. collation, trigger, computed column, foreign key, ขนาด';
SELECT CAST(DATABASEPROPERTYEX(DB_NAME(), 'Collation') AS varchar(100)) AS db_collation,
       (SELECT COUNT(*) FROM sys.triggers WHERE parent_class = 1) AS table_triggers,
       (SELECT COUNT(*) FROM sys.computed_columns) AS computed_columns,
       (SELECT COUNT(*) FROM sys.foreign_keys) AS foreign_keys,
       (SELECT COUNT(*) FROM sys.tables) AS tables_,
       (SELECT SUM(p.rows) FROM sys.partitions p JOIN sys.tables t ON t.object_id = p.object_id WHERE p.index_id IN (0,1)) AS total_rows;
