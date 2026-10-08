# แผน 3: PostgreSQL HA (Patroni) 3 เครื่อง

สถานะ: **ข้อเสนอ ยังไม่ได้ตัดสินใจ** · diagram: [infra-diagram-plan3.svg](infra-diagram-plan3.svg)
เป้าหมาย: ทุกบริการฝั่ง data สลับเครื่องเองอัตโนมัติ ข้อมูลที่ commit แล้วไม่หาย และใช้ซอฟต์แวร์ฟรีทั้งหมด

## ภาพรวม

| ชั้น | ใช้ | หน้าที่ |
| --- | --- | --- |
| DB | PostgreSQL 17 × 3 | leader 1 + replica แบบ sync 1 + แบบ async 1 |
| เลือก leader | Patroni + etcd × 3 | ตรวจสุขภาพ, โหวต, promote replica, กัน split-brain |
| pool connection | PgBouncer (ทุกเครื่อง) | ลดจำนวน connection จริงที่เข้า PostgreSQL |
| ทางเข้า | HAProxy (Swarm global service บน erp-app-01/02) | ถาม Patroni ว่าใครเป็น leader แล้วส่ง traffic ไปที่นั่น — แอปไม่ต้องรู้ |
| cache / pub-sub | Valkey + Sentinel × 3 | แทน Redis (แยกมาจาก Redis 7.2 ใช้ client เดิมได้) · Sentinel promote replica เอง |
| queue | RabbitMQ 4 cluster × 3 + quorum queue | คิวมีสำเนา 3 เครื่อง (Raft) เครื่องหนึ่งล่มคิวไม่หาย |
| ไฟล์ upload | NFS active/standby (เหมือนแผน 2) | **ส่วนเดียวที่ยังสลับด้วยคน** (ดูท้ายไฟล์) |
| backup | pgBackRest บน db-03 | full รายสัปดาห์ + diff รายวัน + WAL ต่อเนื่อง → กู้ถึงวินาที · ส่ง FTP |

### ทำไมไม่ใส่ Citus

Citus กระจายข้อมูลตารางเดียวไปหลายเครื่อง ใช้กับ DB หลายร้อย GB ถึงหลาย TB หรือ SaaS ที่ลูกค้าหลายพันราย
DB นี้ 180 MB และ Citus ที่มี HA ต้องมี coordinator 1 กลุ่ม + worker อย่างน้อย 2 กลุ่ม แต่ละกลุ่มมี replica = **6 เครื่องขึ้นไป**
ได้ความซับซ้อนเพิ่มโดยไม่ได้ประโยชน์ · Patroni รองรับ Citus อยู่แล้ว ถ้าวันหนึ่งข้อมูลโตจริงค่อยเพิ่มได้โดยไม่ต้องรื้อ

### ทำไม HAProxy ไม่ใช่ให้แอปคุยกับ Sentinel ตรง

go-chat-api ใช้ `redis` v4 และ `@socket.io/redis-adapter` ซึ่งไม่รองรับ Sentinel · ถ้าให้ HAProxy เช็ก `role:master` แทน
แอปต่อ `data-proxy:6379` ที่เดียวเหมือนต่อ Redis ตัวเดียว **ไม่ต้องแก้โค้ดฝั่ง Redis และ RabbitMQ เลย**

## เครื่อง

| VM | IP | vCPU | RAM | OS | ข้อมูล | backup | datastore |
| --- | --- | ---: | ---: | --- | --- | --- | --- |
| erp-db-01 | 192.168.88.12 | 4 | 8 GB | 30 GB | 120 GB | – | DS-A |
| erp-db-02 | 192.168.88.13 | 4 | 8 GB | 30 GB | 120 GB | – | DS-B |
| erp-db-03 | 192.168.88.14 (เสนอ) | 4 | 8 GB | 30 GB | 120 GB | 200 GB (pgBackRest repo) | **DS-C** |
| VIP NFS | 192.168.88.15 | | | | | | |

PostgreSQL ไม่มีเพดาน CPU / RAM / 10 GB แบบ Express — ขยายเครื่องได้ตามต้องการ

### ⚠ ต้องมี 3 failure domain

etcd, Sentinel และ RabbitMQ quorum ต้องได้เสียง **2 ใน 3** ถึงจะทำงานต่อ
ถ้ามีแค่ DS-A / DS-B แล้ววาง 2 เครื่องไว้ฝั่งเดียวกัน ฝั่งนั้นหาย = เหลือ 1 เสียง = **DB หยุดรับเขียนทั้งระบบ** (Patroni ลด leader เป็นอ่านอย่างเดียวเพื่อกันข้อมูลแตก)

| มีอะไร | วาง db-03 ที่ |
| --- | --- |
| datastore ที่ 3 (NAS / RAID อีกชุด) | DS-C |
| ESXi host ที่ 2 ที่มีดิสก์ของตัวเอง | ดิสก์ local ของ host นั้น |
| มีแค่ DS-A / DS-B จริง ๆ | ทำ db-03 เป็น **witness เล็ก** (1 vCPU / 1 GB: etcd + Sentinel เท่านั้น) บนเครื่องอื่นที่ไม่ใช่ 2 datastore นี้ เช่น mini PC / NAS ที่รัน VM ได้ — RabbitMQ เหลือ 2 เครื่อง (ไม่ใช้ quorum queue) |

## พอร์ต

| พอร์ต | ที่ไหน | ใช้ |
| --- | --- | --- |
| 5432 | db ทุกเครื่อง | PostgreSQL (เฉพาะ PgBouncer / replica / pgBackRest เข้า) |
| 6432 | db ทุกเครื่อง | PgBouncer |
| 8008 | db ทุกเครื่อง | Patroni REST (`/primary`, `/replica`, `/health`) — HAProxy ใช้เช็ก |
| 2379 / 2380 | db ทุกเครื่อง | etcd client / peer |
| 6379 / 26379 | db ทุกเครื่อง | Valkey / Sentinel |
| 5672 / 15672 / 25672 / 4369 | db ทุกเครื่อง | RabbitMQ AMQP / UI / cluster / epmd |
| 2049 | VIP .15 | NFS |
| `data-proxy:5432` | overlay ใน Swarm | แอปต่อที่นี่ → leader (ผ่าน PgBouncer 6432) |
| `data-proxy:5433` | overlay | replica (report อ่านอย่างเดียว) |
| `data-proxy:6379` | overlay | Valkey master |
| `data-proxy:5672` | overlay | RabbitMQ (เครื่องไหนก็ได้) |

## ค่าหลัก

**Patroni**

```yaml
bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    synchronous_mode: true            # commit รอ replica 1 ตัวยืนยัน → สลับเครื่องข้อมูลไม่หาย
    synchronous_mode_strict: false    # ถ้า replica หายหมด ยังเขียนต่อได้ (ไม่หยุดทั้งระบบ)
    postgresql:
      use_pg_rewind: true             # leader เก่ากลับมาเป็น replica ได้เองไม่ต้องสร้างใหม่
      parameters:
        wal_level: replica
        max_connections: 200
        archive_mode: "on"
        archive_command: "pgbackrest --stanza=erp archive-push %p"
        timezone: "Asia/Bangkok"
```

**HAProxy** (ส่วน PostgreSQL / Valkey)

```
listen pg_primary
  bind *:5432
  option httpchk GET /primary
  http-check expect status 200
  default-server inter 2s fall 2 rise 2 on-marked-down shutdown-sessions
  server db1 192.168.88.12:6432 check port 8008
  server db2 192.168.88.13:6432 check port 8008
  server db3 192.168.88.14:6432 check port 8008

listen valkey_master
  bind *:6379
  option tcp-check
  tcp-check send "AUTH ${VALKEY_PASSWORD}\r\n"
  tcp-check expect string +OK
  tcp-check send "info replication\r\n"
  tcp-check expect string role:master
  server db1 192.168.88.12:6379 check inter 2s
  server db2 192.168.88.13:6379 check inter 2s
  server db3 192.168.88.14:6379 check inter 2s
```

**PgBouncer:** `pool_mode = transaction`, `max_prepared_statements = 200` (ต้อง PgBouncer ≥ 1.21 — Npgsql ใช้ prepared statement)
**Valkey Sentinel:** `quorum 2`, `down-after-milliseconds 5000`, `failover-timeout 30000`
**RabbitMQ:** ตั้ง default queue type ของ vhost เป็น `quorum` — คิวที่แอปประกาศแบบ durable จะเป็น quorum เอง (ตรวจว่า `log_queue` ประกาศแบบ durable ไม่ใช่ exclusive / auto-delete)
**pgBackRest:** `repo1-cipher-type=aes-256-cbc` (เข้ารหัสในตัว) · `backup-standby=y` (ดึงจาก replica ไม่โหลด leader) · repo ที่ `/srv/pgbackrest` แล้ว `backup-offsite.sh` mirror ขึ้น FTP

## เมื่อมีอะไรล่ม

| เหตุการณ์ | ผล | เวลา |
| --- | --- | --- |
| leader (db-01) ล่ม | Patroni promote db-02 (sync replica) · HAProxy เห็นใน 4 วินาทีแล้วส่งไป db-02 · ข้อมูลไม่หาย | 10–30 วินาที |
| replica ล่ม | ไม่กระทบ · ถ้าเป็น sync replica Patroni ยก db-03 เป็น sync แทน | 0 |
| Valkey master ล่ม | Sentinel promote replica · HAProxy ย้าย · socket.io / SignalR reconnect | 5–15 วินาที |
| RabbitMQ เครื่องหนึ่งล่ม | quorum queue ยังมี 2 สำเนา · client reconnect ผ่าน HAProxy | ไม่กี่วินาที |
| leader โดนตัดเครือข่ายแต่ยังทำงาน | ต่อ etcd ไม่ได้ → ครบ ttl ลดตัวเองเป็น replica · อีก 2 เครื่องเลือก leader ใหม่ → **ไม่มี split-brain** | ≤ 30 วินาที |
| datastore 1 ก้อนหาย (วางครบ 3 domain) | เหลือ 2 เสียง ทำงานต่อทุกบริการ | 10–30 วินาที |
| db-01 ที่ถือ NFS ล่ม | **ไฟล์ upload ใช้ไม่ได้จนกว่าจะสั่งย้าย** VIP .15 ไป db-02 แล้ว restart erpapi / chat-api | คนสั่ง ~5 นาที |
| leader เก่ากลับมา | pg_rewind แล้วเข้ามาเป็น replica เอง | อัตโนมัติ |

## งานฝั่งแอป (SQL Server → PostgreSQL)

ใช้ Phase 0 เดียวกับ [mysql-migration-plan.md](mysql-migration-plan.md) (helper ส่ง parameter จริง แทนการต่อ string 2,537 จุด) — ตัวเลขขนาดงานอยู่ในไฟล์นั้น
สิ่งที่ต่างจาก MySQL:

| เรื่อง | PostgreSQL | ผล |
| --- | --- | --- |
| package .NET | `Npgsql.EntityFrameworkCore.PostgreSQL` 9.x + `Npgsql` (ของทีมเดียวกัน รองรับ EF Core 9) | ✓ |
| package Node | `pg` | ✓ |
| named parameter | **มี** `SELECT * FROM set_invoice_detail(p_invoice_no => $1, p_seq => $2)` | ง่ายกว่า MySQL — เก็บชื่อ parameter ไว้ได้ |
| SP ที่คืนข้อมูล | เขียนเป็น `FUNCTION ... RETURNS TABLE(...)` เรียกด้วย `SELECT * FROM fn(...)` | |
| SP คืนหลายชุดข้อมูล | function คืนได้ชุดเดียว → แยกเป็นหลาย function (โค้ดใช้ `DataSet` 5 จุด) | |
| ⚠ ชื่อคอลัมน์ | ชื่อที่ไม่ใส่ `"..."` จะกลายเป็นตัวเล็ก → JSON ที่ API ส่งออกเปลี่ยนจาก `InvoiceNo` เป็น `invoiceno` = **CRM / แอป onsite / chat พังทั้งหมด** | ทุก function ต้องประกาศคอลัมน์ผลลัพธ์แบบ `RETURNS TABLE("InvoiceNo" varchar, ...)` และ SQL ในโค้ดต้อง `AS "InvoiceNo"` — ต้องมีชุดทดสอบเทียบ response ทุก endpoint |
| ⚠ ตัวพิมพ์เล็ก/ใหญ่ | SQL Server (collation `_CI_`) มองว่า `'abc' = 'ABC'` — PostgreSQL ไม่ | ใช้ ICU collation แบบ nondeterministic หรือ `citext` กับคอลัมน์รหัส / email / username |
| ต่อ string | `\|\|` — `NULL \|\| 'x'` ได้ NULL **เหมือน SQL Server** | ง่ายกว่า MySQL |
| `TOP n` / `ISNULL` / `GETDATE()` | `LIMIT n` / `COALESCE` / `LOCALTIMESTAMP` | |
| `IDENTITY` / `SCOPE_IDENTITY()` | `GENERATED ALWAYS AS IDENTITY` / `RETURNING id` | |
| `MERGE` | มีตั้งแต่ PostgreSQL 15 | ✓ |
| `TRY/CATCH`, `RAISERROR` | `BEGIN ... EXCEPTION WHEN ...`, `RAISE EXCEPTION` | |
| `#temp`, table variable | `CREATE TEMP TABLE ... ON COMMIT DROP` | |
| `bit` / `datetime` / `uniqueidentifier` / `nvarchar(max)` / `varbinary(max)` | `boolean` / `timestamp` / `uuid` / `text` / `bytea` | `bit` → `boolean` JSON ยังเป็น true/false เหมือนเดิม |

**เครื่องมือแปลง (ฟรี):** pgloader (ย้าย schema + ข้อมูลจาก SQL Server ตรง ๆ), AWS SCT (แปลง SP เป็น PL/pgSQL ชุดแรก), compare harness แบบเดียวกับแผน MySQL
**ทางลัดที่ต้องลองก่อนตัดสินใจ:** **Babelfish for PostgreSQL** — PostgreSQL ที่รับ connection แบบ SQL Server (TDS port 1433) และรัน T-SQL ได้ ถ้า SP ส่วนใหญ่ผ่าน จะลดงานฝั่งแอปลงมาก
แต่ Babelfish เป็น PostgreSQL รุ่นดัดแปลง ต้องทดสอบว่า Patroni / pgBackRest ใช้ด้วยกันได้ และ T-SQL บางคำสั่งยังไม่รองรับ — ใช้ inventory (`data/mssql-inventory.sql`) + Babelfish Compass ประเมินก่อน

## ประเมินเวลา

| งาน | ชั่วโมง |
| --- | ---: |
| Phase 0 (เหมือนแผน MySQL) | 220–300 |
| แปลง SP ~561 ตัวเป็น function + ชื่อคอลัมน์ `"..."` + compare harness | 350–600 |
| SQL ตรงในโค้ด + EF model + migration 26 ไฟล์ + collation ภาษาไทย / case-insensitive | 100–150 |
| go-ticker-job | ? |
| infra: Patroni / etcd / PgBouncer / HAProxy / Valkey / RabbitMQ cluster / pgBackRest / Zabbix + ซ้อมล่มทุกแบบในตาราง | 80–120 |
| ย้ายข้อมูล + ซ้อม 2 รอบ | 40–60 |
| ทดสอบ API ทุก endpoint (เทียบ JSON) / UAT | 150–250 |
| **รวม** | **~940–1,480 ชม.** |

ถ้า Babelfish ใช้ได้ส่วนใหญ่ งาน SP และ SQL ในโค้ดอาจลดลงครึ่งหนึ่ง — ต้องรัน Compass ก่อนถึงจะรู้

## เทียบ 4 แผน

| | ปัจจุบัน | แผน 2 (log shipping) | MySQL InnoDB Cluster | แผน 3 (PostgreSQL + Patroni) |
| --- | --- | --- | --- | --- |
| เครื่อง DB | 1 | 2 | 3 | 3 (หรือ 2 + witness) |
| สลับเครื่อง | กู้จาก backup | คน / อัตโนมัติแบบมีเงื่อนไข 1–2 นาที | อัตโนมัติ | อัตโนมัติ 10–30 วินาที |
| ข้อมูลหาย | ≤ 24 ชม. (≤ 15 นาทีถ้าเพิ่ม log backup) | ≤ 1–5 นาที | 0 | 0 |
| Redis / RabbitMQ HA | ไม่มี | standby | ไม่อยู่ในแผน | อัตโนมัติ |
| license | 0 | 0 | 0 | 0 |
| ค่าแรง | – | ~40–80 ชม. | ~830–1,350 ชม. | ~940–1,480 ชม. |
| แก้โค้ดแอป | ไม่ | ไม่ | ทุก endpoint | ทุก endpoint |

**ข้อแนะนำ:** ลำดับเดิมยังใช้ได้ — ทำ Phase 0 ก่อน (ต้องทำอยู่แล้ว) → รัน inventory + Babelfish Compass → ค่อยเลือกระหว่างแผน 3 กับซื้อ SQL Server Standard
ระหว่างรอ ทำแผน 2 ไว้ก่อนได้ เพราะ VM db-02 และการแบ่ง datastore ใช้ต่อในแผน 3 ได้เลย

## ส่วนที่ยังไม่อัตโนมัติ: ไฟล์ upload

NFS ยังเป็น active/standby (lsyncd + VIP .15) เพราะไฟล์ระบบแบบกระจาย (GlusterFS / CephFS) หนักเกินขนาดงานนี้
ทางที่ดีกว่าในระยะยาวคือเก็บไฟล์เป็น **object storage แบบ S3** (MinIO หรือ Garage 3 เครื่อง) ซึ่งมีสำเนาและสลับเครื่องเอง
แต่ต้องแก้ erpapi / chat-api ให้อัปโหลดผ่าน S3 API แทนการเขียนไฟล์ลงดิสก์ — แยกเป็นงานอีกก้อน
