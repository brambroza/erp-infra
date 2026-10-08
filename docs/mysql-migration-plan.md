# แผนย้าย SQL Server → MySQL InnoDB Cluster

สถานะ: **ข้อเสนอ ยังไม่ได้ตัดสินใจ** · เป้าหมาย: DB ฟรีที่สลับเครื่องเองอัตโนมัติ (ไม่กี่วินาที, ข้อมูลไม่หาย)
เทียบกับทางเลือกอื่นอยู่ท้ายไฟล์ — อ่านส่วน "ขนาดงานจริง" ก่อนตัดสินใจ

## ขนาดงานจริง (นับจากโค้ด 2026-10-08)

| ที่ | สิ่งที่ต้องแก้ | จำนวน |
| --- | --- | ---: |
| go-coreapi | stored procedure ที่ถูกเรียก (ชื่อไม่ซ้ำ) | **561** |
| go-coreapi | จุดเรียก `"exec dbo.xxx @a='...'"` แบบต่อ string | 733 |
| go-coreapi | จุดต่อค่าลง SQL ด้วย `'" + ... + "'` | 2,537 |
| go-coreapi | ไฟล์ที่ใช้ `DBConn` (GetDataTable 711, ExecuteOnly 219, ExecuteTran 136 ครั้ง) | 90 |
| go-coreapi | SQL ที่เขียนตรงในโค้ด (`TOP` 130, `ISNULL` 345, `GETDATE` 22, `OFFSET` 9, `CONVERT` 6) | ~200 คำสั่ง |
| go-coreapi | EF Core: DbContext 2 ตัว, `DbSet` 60, ชนิดคอลัมน์เฉพาะ SQL Server (`datetime2`, `nvarchar(max)`, `GETDATE()`, `sysutcdatetime()`) | ~150 จุด |
| go-coreapi | ไฟล์ migration ใน `Database/Migrations/` | 26 |
| go-chat-api | SP ที่เรียก, `.input()` 278 จุด, `.query()` 39 จุด, ใช้ `recordset` 96 จุด | 22 SP |
| go-ticker-job | **ยังไม่ได้ดูโค้ด** (ไม่อยู่ใน session นี้) — ต้องนับเพิ่ม | ? |
| ใน DB | proc / function / trigger / view / ตารางไม่มี PK | รัน `data/mssql-inventory.sql` |

ข้อเท็จจริงที่กำหนดแผน:

1. **MySQL ไม่มี named parameter** — `exec dbo.setInvoiceDetail @InvoiceNo='..', @Seq=1` ต้องเป็น `CALL setInvoiceDetail(?, ?, ...)` เรียงตามลำดับ → **ทั้ง 733 จุดต้องแก้มือ** และต้องรู้ลำดับ parameter ของแต่ละ SP
2. **SP ทุกตัวเป็น T-SQL** — MySQL รันไม่ได้สักตัว ต้องแปลงทั้ง ~561+ ตัว (เครื่องมือแปลงได้ราว 60–80% ที่เหลือแก้มือ)
3. **การต่อ string 2,537 จุดคือ SQL injection อยู่แล้ววันนี้** (ดู CLAUDE.md ข้อ 3.1) — งานแก้ข้อนี้ต้องทำอยู่ดีไม่ว่าจะย้ายหรือไม่ และเป็นงานก้อนเดียวกับการเปลี่ยน DB

## ต้องใช้อะไรบ้าง (ครบ 100%)

### A. Infra

| อะไร | รายละเอียด | ค่าใช้จ่าย |
| --- | --- | --- |
| VM DB **3 เครื่อง** | InnoDB Cluster ต้อง 3 เครื่องขึ้นไป (ไม่มีแบบ 2 เครื่อง + witness) · 4 vCPU / 8 GB / ดิสก์ข้อมูล 120 GB / backup 120 GB ต่อเครื่อง · วาง DS-A, DS-B, และเครื่องที่ 3 แยก (ถ้ามี datastore ที่ 3 ดีที่สุด) | VM เพิ่ม 1 เครื่องจากแผน 2 |
| MySQL Server 8.4 LTS Community | GPL ฟรี · Group Replication โหมด single-primary | 0 |
| MySQL Shell 8.4 | `dba.createCluster()`, `util.dumpInstance()` | 0 |
| MySQL Router 8.4 | รันบน erp-app-01 / erp-app-02 เครื่องละตัว แอปต่อ `localhost:6446` (เขียน) / `6447` (อ่าน) — **ไม่ต้องใช้ Data VIP** | 0 |
| Percona XtraBackup 8.4 | backup แบบ physical ทุกคืน + binlog สำหรับกู้ถึงนาที แทน `mssql-backup.sh` · ส่ง FTP ต่อด้วย `backup-offsite.sh` (ปรับ path) | 0 |
| Zabbix | template "MySQL by Zabbix agent 2" + เช็ก `performance_schema.replication_group_members` (สมาชิก ONLINE = 3) | 0 |

ค่าตั้งที่ **ต้อง** ตั้งก่อนสร้าง data directory (เปลี่ยนทีหลังไม่ได้):

| ค่า | ตั้งเป็น | ทำไม |
| --- | --- | --- |
| `lower_case_table_names` | `1` | SQL Server ไม่สนตัวพิมพ์ชื่อตาราง โค้ดเขียน `Invoice_Detail` / `invoice_detail` ปนกัน — MySQL บน Linux สนตัวพิมพ์ |
| `character_set_server` | `utf8mb4` | ภาษาไทย / emoji จาก LINE |
| `collation_server` | เลือกหลังทดสอบเรียงและค้นภาษาไทย (เริ่มที่ `utf8mb4_0900_as_ci`) | ต้องให้ผลเรียง/ค้นหาเหมือน collation เดิม (ดูข้อ 7 ของ inventory) |
| `transaction_isolation` | `READ-COMMITTED` | ค่าเริ่มต้นของ SQL Server · MySQL เริ่มที่ REPEATABLE-READ ผลของ query บางตัวจะต่าง |
| `sql_mode` | ค่าเริ่มต้น 8.4 (มี `STRICT_TRANS_TABLES`) | SQL Server ปฏิเสธข้อมูลผิดชนิด MySQL ต้องทำเหมือนกัน |
| `time_zone` | `'+07:00'` | `GETDATE()` เดิมเป็นเวลาไทย · ส่วนที่ใช้ `sysutcdatetime()` ให้ใช้ `UTC_TIMESTAMP(6)` |
| `group_concat_max_len` | `1048576` | แทน `STRING_AGG` / `FOR XML PATH` ไม่ให้ตัดข้อความเงียบ ๆ |

### B. เครื่องมือแปลง

| อะไร | ใช้ทำ |
| --- | --- |
| **AWS Schema Conversion Tool** (ฟรี ใช้ offline ได้ ไม่ต้องมี AWS) หรือ **SQLines** | แปลง schema + SP / function / view ชุดแรก และรายงานจุดที่แปลงไม่ได้ |
| MySQL Workbench (Migration Wizard) | ตรวจ schema ที่ได้ เทียบชนิดข้อมูล |
| script ย้ายข้อมูล (เขียนเอง) | `bcp` ออกเป็นไฟล์ → `LOAD DATA LOCAL INFILE` → นับแถว + checksum ทุกตาราง — ต้องรันซ้ำได้สำหรับซ้อมและวันจริง |
| **SP compare harness** (เขียนเอง) | เรียก SP ตัวเดียวกันด้วย input เดียวกันทั้งบน SQL Server และ MySQL แล้วเทียบผลทีละแถว — นี่คือสิ่งที่ทำให้มั่นใจได้ว่า "ครบ 100%" |

### C. go-coreapi (.NET 9)

| เปลี่ยน | จาก | เป็น |
| --- | --- | --- |
| package EF | `Microsoft.EntityFrameworkCore.SqlServer` 9.0.1 | `Pomelo.EntityFrameworkCore.MySql` รุ่นที่รองรับ EF Core 9 (ถ้ายังไม่ GA ใช้ `MySql.EntityFrameworkCore` 9.x ของ Oracle) |
| package ADO.NET | `Microsoft.Data.SqlClient` 5.2.2 | `MySqlConnector` |
| `UseSqlServer(...)` | `DatabaseContext`, `HrDbContext` | `UseMySql(..., ServerVersion.Parse("8.4"))` |
| ชนิดคอลัมน์ใน model | `datetime2` → `datetime(6)` · `nvarchar(max)` → `longtext` · `varchar(n)` เหมือนเดิม · `decimal` เหมือนเดิม · `time` เหมือนเดิม | |
| ค่าเริ่มต้น | `GETDATE()` → `CURRENT_TIMESTAMP(6)` · `sysutcdatetime()` → `UTC_TIMESTAMP(6)` | |
| `DB/DBConn.cs` | static `SqlConnection` / `SqlCommand` | **เขียนใหม่** เป็น helper ที่ไม่ static (แก้หนี้ข้อ 2 ใน CLAUDE.md ไปด้วย) |
| 733 จุด `exec dbo.xxx @p='..'` | ต่อ string | `Db.CallProc("xxx", new { InvoiceNo, Seq, ... })` → helper เรียง parameter ตามลำดับที่อ่านจาก `information_schema.parameters` และส่งเป็น parameter จริง |
| SQL ตรงในโค้ด ~200 คำสั่ง | `TOP n` · `ISNULL` · `GETDATE()` · `[ชื่อ]` · `+` ต่อ string · `OFFSET..FETCH` · `CONVERT(varchar, d, 103)` | `LIMIT n` · `IFNULL` · `NOW()` · `` `ชื่อ` `` · `CONCAT()` (ระวัง: `NULL + 'x'` เดิมได้ NULL) · `LIMIT .. OFFSET` · `DATE_FORMAT` |
| `SqlDbType.*` | NVarChar, VarBinary, Image, Time, Date, Int | `MySqlDbType.*` (Image/VarBinary → `LongBlob`) |
| `DataTable` จาก `SqlDataAdapter` | | `MySqlDataAdapter` — ผลเหมือนกัน ชื่อ column ตรงตาม `AS` ใน SP |
| connection string | `Server=...;Database=GoAlongDatabase;User Id=erp_app` | `Server=127.0.0.1;Port=6446;Database=goalongdatabase;User=erp_app;...` (ผ่าน Router) |
| migration ใหม่ | `.sql` แบบ T-SQL `IF NOT EXISTS ... ALTER TABLE` | แบบ MySQL (`CREATE TABLE IF NOT EXISTS`, `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` ไม่มีใน MySQL → เช็กผ่าน `information_schema`) — แปลง 26 ไฟล์เดิม |

### D. go-chat-api (Node.js)

| เปลี่ยน | จาก | เป็น |
| --- | --- | --- |
| package | `mssql` | `mysql2` (promise pool) |
| helper | `pool.request().input('a', sql.VarChar(50), v).execute('dbo.x')` | `callProc('x', { a: v })` ที่คืนรูป `{ recordset, recordsets, rowsAffected }` **เหมือน mssql** → controller 96 จุดที่อ่าน `recordset` ไม่ต้องแก้ |
| 278 `.input()` | ระบุชื่อ + ชนิด | object ชื่อ → helper เรียงตามลำดับ parameter ของ SP |
| 39 `.query()` | T-SQL | SQL แบบ MySQL (กฎเดียวกับข้อ C) |
| ตารางที่ query ตรง | `CompanySocialChannel`, `Accounts`, `Dashboard_Service_Configs`, `NisChatMessages` | ตรวจ `TOP`, `GETDATE`, ชนิดวันเวลา |
| env | `DB_HOST`, `DB_USER`, ... | เพิ่ม `DB_PORT=6446` (Router) |

### E. ใน DB

| อะไร | งาน |
| --- | --- |
| ~561+ stored procedure | แปลงด้วย SCT → แก้มือ → ผ่าน compare harness ทุกตัว |
| function / view / trigger | function แบบ table-valued ไม่มีใน MySQL → แปลงเป็น view หรือ proc · trigger ของ SQL Server ทำงานทีละชุด (`inserted`/`deleted`) ของ MySQL ทีละแถว (`NEW`/`OLD`) → เขียนใหม่ |
| ตารางไม่มี primary key | **เพิ่ม PK ทุกตาราง** (Group Replication ไม่ยอมให้เขียน) |
| ชนิดข้อมูล | `uniqueidentifier` → `CHAR(36)` · `bit` → `TINYINT(1)` · `money` → `DECIMAL(19,4)` · `datetimeoffset` → `DATETIME(6)` เก็บ UTC · `nvarchar(max)` → `LONGTEXT` · `image`/`varbinary(max)` → `LONGBLOB` · `IDENTITY` → `AUTO_INCREMENT` |
| feature T-SQL | `#temp` → `CREATE TEMPORARY TABLE` · table variable → temporary table · `TRY/CATCH` → `DECLARE ... HANDLER` · `RAISERROR`/`THROW` → `SIGNAL` · `sp_executesql` → `PREPARE`/`EXECUTE` · `MERGE` → `INSERT ... ON DUPLICATE KEY UPDATE` · `OUTPUT INSERTED` → `LAST_INSERT_ID()` / SELECT ซ้ำ · `STRING_AGG`/`FOR XML PATH` → `GROUP_CONCAT` · `PIVOT` → `CASE` · `@@ROWCOUNT` → `ROW_COUNT()` · `NEWID()` → `UUID()` |
| user / สิทธิ์ | `erp_app` ใหม่ใน MySQL: `SELECT, INSERT, UPDATE, DELETE, EXECUTE` บน schema เดียว (เท่าสิทธิ์ที่ `mssql-app-user.sh` ให้วันนี้) |

### F. ทดสอบ

| ชั้น | อะไร |
| --- | --- |
| SP | compare harness ผ่าน **ทุกตัว** ด้วย input จริงจาก log production อย่างน้อย 3 ชุดต่อ SP |
| API | ชุดทดสอบ endpoint (Postman/Newman) ที่ CRM, แอป onsite, chat ใช้ — เทียบ response กับระบบเดิม |
| ข้อมูล | นับแถว + checksum ทุกตาราง หลังย้ายแต่ละรอบ |
| ภาษาไทย | เรียงชื่อ, ค้นแบบ `LIKE`, ตัวอักษรพิเศษ / emoji จาก LINE |
| ประสิทธิภาพ | หน้า report และ dashboard ที่หนักที่สุด 20 หน้า ต้องไม่ช้ากว่าเดิม |
| HA | ปิด primary ระหว่างมีคนใช้ → Router ย้ายเองไม่เกิน 30 วินาที, ไม่มี transaction ที่ยืนยันแล้วหาย |
| ผู้ใช้ | UAT ทุกแผนก 1–2 สัปดาห์บนระบบทดสอบ |

## ลำดับงาน

### Phase 0 — ทำบน SQL Server ก่อน (คุ้มแม้สุดท้ายไม่ย้าย)

1. เขียน helper `Db.CallProc(name, params)` ใน go-coreapi ที่ส่ง parameter จริง (ไม่ต่อ string) ใช้กับ SQL Server ได้ทันที
2. ทยอยเปลี่ยน 733 จุด `exec ...` ไปใช้ helper — **ปิด SQL injection ไปพร้อมกัน**
3. แทน `DBConn` แบบ static ด้วย connection ต่อ request (แก้ปัญหา thread-safety)
4. go-chat-api: ห่อ `mssql` ด้วย `callProc()` ตัวเดียว
5. ทุก endpoint ผ่านทดสอบบน SQL Server เหมือนเดิม → deploy production ได้เลย

พอจบ Phase 0 การเปลี่ยน DB เหลือแค่: เปลี่ยน helper 2 ตัว + แปลง SP + แก้ SQL ตรง ~200 คำสั่ง

### Phase 1 — แปลง DB (ไม่กระทบ production)

1. รัน `data/mssql-inventory.sql` → ได้จำนวนจริงและขนาดของ SP ทุกตัว
2. ตั้ง MySQL ตัวเดียวสำหรับพัฒนา + SCT แปลง schema และ SP ชุดแรก
3. เพิ่ม PK ตารางที่ขาด, กำหนด collation หลังทดสอบภาษาไทย
4. แก้ SP ที่แปลงไม่ผ่าน และสร้าง compare harness
5. script ย้ายข้อมูล + ตรวจนับ

### Phase 2 — แอปบน MySQL (สภาพแวดล้อมทดสอบ)

1. สลับ helper เป็น MySqlConnector / mysql2 ด้วย config (`DB_ENGINE=mysql`) — โค้ดเดียวกันรันได้ทั้งสอง DB ช่วงเปลี่ยนผ่าน
2. EF Core → Pomelo, แก้ model
3. แก้ SQL ตรงในโค้ด
4. ทดสอบชั้น F ทั้งหมด

### Phase 3 — Infra

1. 3 VM + InnoDB Cluster + Router บน app ทั้งสอง
2. XtraBackup + binlog → `/srv/mysql/backup` → FTP
3. Zabbix + ซ้อมสลับ primary / ดับเครื่อง / ตัดสายเครือข่าย

### Phase 4 — ย้ายจริง

1. ซ้อมย้ายเต็มรอบอย่างน้อย 2 ครั้ง (จับเวลา)
2. วันจริง: ปิดแอป → ย้ายข้อมูล → ตรวจนับ → เปิดแอปชี้ MySQL → ทดสอบ → เปิดใช้
3. SQL Server เก็บไว้อ่านอย่างเดียว 30 วัน · ย้อนกลับได้ก่อนเปิดให้ผู้ใช้เขียนเท่านั้น (ไม่มี sync ย้อนจาก MySQL กลับ SQL Server)

## ประเมินเวลา (คร่าว ๆ — ปรับหลังได้ผล inventory)

| งาน | ชั่วโมง |
| --- | ---: |
| Phase 0: helper + เปลี่ยน 733 จุด + DBConn + Node helper + ทดสอบ | 220–300 |
| แปลง SP ~561 ตัว (เฉลี่ย 30–60 นาที/ตัว หลัง SCT) + compare harness | 300–560 |
| SQL ตรง ~200 คำสั่ง + EF model + migration 26 ไฟล์ | 80–120 |
| go-ticker-job (ยังไม่รู้ขนาด) | ? |
| script ย้ายข้อมูล + ซ้อม 2 รอบ | 40–60 |
| Infra 3 node + Router + backup + Zabbix + ซ้อม HA | 40–60 |
| ทดสอบ API / ภาษาไทย / ประสิทธิภาพ / UAT | 150–250 |
| **รวม** | **~830–1,350 ชม.** |

≈ คนเดียว 5–8 เดือน · 2 คน 3–4 เดือน (ไม่รวมงาน feature ปกติที่ต้องทำคู่กัน และระหว่างนั้นทุก SP ใหม่ต้องเขียน 2 แบบ)

## เทียบทางเลือก

| | ย้ายไป MySQL InnoDB Cluster | SQL Server Standard + Basic AG | แผน 2 (log shipping, Express) |
| --- | --- | --- | --- |
| license | 0 | ~US$8,000 ต่อเครื่องหลัก (ราคา list ที่รู้ล่าสุด ต้องเช็กกับตัวแทน) | 0 |
| ค่าแรง | ~830–1,350 ชม. | ~40–80 ชม. (infra + Pacemaker) | ~40 ชม. |
| สลับเครื่อง | อัตโนมัติ ไม่กี่วินาที–30 วิ | อัตโนมัติ ไม่กี่วินาที | คนสั่ง ~10 นาที |
| ข้อมูลหาย | 0 | 0 | ≤ 5 นาที |
| ความเสี่ยง | สูง (แตะทุก endpoint) | ต่ำ (ไม่แก้โค้ด) | ต่ำ |
| ได้แถม | ปิด SQL injection, DBConn ปลอดภัย, ไม่มีเพดาน 10 GB ของ Express | ไม่มีเพดาน Express | – |

**ข้อแนะนำ:** ทำ **Phase 0 ก่อนไม่ว่าจะเลือกทางไหน** (เป็นงานที่ต้องทำอยู่แล้วเพื่อความปลอดภัย) แล้วตัดสินใจเรื่อง DB หลังได้ผล inventory
ถ้าเป้าคือ "สลับเครื่องอัตโนมัติ" อย่างเดียว ซื้อ Standard ถูกกว่าค่าแรงย้ายหลายเท่า
ถ้าเป้าคือเลิกผูกกับ Microsoft ระยะยาว หรือ DB จะโตเกิน 10 GB เร็ว ๆ นี้ ค่อยเดินต่อ Phase 1–4
