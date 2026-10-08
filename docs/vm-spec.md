# Spec VM และการป้องกันดิสก์พัง

ใช้กับแผน 2 (มี erp-db-02 — ดู [infra-diagram-plan2.svg](infra-diagram-plan2.svg)) · ถ้ายังไม่ทำแผน 2 ข้าม erp-db-02 และ Data VIP
ค่าที่วัดจริงและสูตรคำนวณอยู่ใน [architecture.md](architecture.md#resource)

## Spec ต่อเครื่อง

| VM | IP | vCPU | RAM | ดิสก์ OS | ดิสก์ข้อมูล `/srv` | ดิสก์ backup `/srv/mssql/backup` |
| --- | --- | ---: | ---: | --- | --- | --- |
| erp-gw-01 | 192.168.88.101 | 1 | 2 GB | 20 GB · **DS-A** | – | – |
| erp-gw-02 | 192.168.88.102 | 1 | 2 GB | 20 GB · **DS-B** | – | – |
| erp-app-01 | 192.168.88.111 | 4 | 8 GB | 40 GB · **DS-A** | – | – |
| erp-app-02 | 192.168.88.112 | 4 | 8 GB | 40 GB · **DS-B** | – | – |
| erp-db-01 | 192.168.88.12 | 4 (1 socket × 4 core) | 8 GB | 30 GB · **DS-A** | 120 GB · **DS-A** | 120 GB · **DS-B** |
| erp-db-02 | 192.168.88.13 | 4 (1 socket × 4 core) | 8 GB | 30 GB · **DS-B** | 120 GB · **DS-B** | 120 GB · **DS-A** |
| erp-ci-01 | 192.168.88.131 | 4 | 4 GB | 40 GB · **DS-B** | – | – |
| VIP gateway | 192.168.88.100 | | | | | |
| VIP data | 192.168.88.15 | | | | | |
| **รวม** | | **22** | **40 GB** | | | |

- **gw 1 vCPU:** พอสำหรับโหลดตอนนี้ (วัดได้ RAM 100 MB) — ถ้า Zabbix เห็น CPU ของ gw เกิน 70% บ่อย หรือ VIP สลับเองโดยไม่มีเครื่องล่ม ให้เพิ่มเป็น 2
- **db 8 GB:** ตั้ง `MSSQL_MEMORY_LIMIT_MB=5120` และลบ 3 บรรทัด `REDIS_MAXMEMORY` / `REDIS_MEM_LIMIT` / `RABBITMQ_MEM_LIMIT` ใน `/opt/data/.env`
- **app / ci ไม่มีดิสก์ข้อมูล:** ไฟล์ upload อยู่บน NFS ของ db, container สร้างใหม่จาก image ได้ — แต่ต้องตั้ง `docker image prune` รายสัปดาห์ไม่ให้ดิสก์ OS เต็ม

### ⚠ SQL Server Express กับจำนวน socket

Express ใช้ CPU ได้ **"1 socket หรือ 4 core แล้วแต่อันไหนน้อยกว่า"**
ถ้า VM เป็น 4 socket × 1 core (ค่าเริ่มต้นของ VMware บางรุ่น) SQL Server จะใช้ได้ **core เดียว** → ต้องตั้ง **Cores per socket = 4** · ตรวจ:

```bash
sudo /opt/erp-infra/data/dc.sh exec -T -e SQLCMDPASSWORD="$(sudo grep -oP '^MSSQL_SA_PASSWORD=\K.*' /opt/data/.env)" mssql \
  /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -Q \
  "SELECT cpu_count, socket_count, cores_per_socket FROM sys.dm_os_sys_info; SELECT COUNT(*) AS cpu_ใช้ได้ FROM sys.dm_os_schedulers WHERE status='VISIBLE ONLINE'"
```

`cpu_ใช้ได้` ต้องได้ 4

## ขนาด datastore

| | DS-A | DS-B |
| --- | --- | --- |
| VM | gw-01 20 · app-01 40 · db-01 30+120 · backup ของ db-02 120 | gw-02 20 · app-02 40 · db-02 30+120 · backup ของ db-01 120 · ci-01 40 |
| รวมดิสก์ | 330 GB | 370 GB |
| + swap ของ VM, snapshot, โต 30% | | |
| **ขั้นต่ำที่ควรมี** | **450 GB** | **500 GB** |

## ป้องกันดิสก์พัง — 4 ชั้น

ดิสก์ "พัง" มี 4 แบบ แต่ละแบบกันคนละที่ ต้องมีครบทุกชั้น

| ชั้น | กันอะไร | ทำที่ไหน | เวลากลับมา |
| --- | --- | --- | --- |
| 1. RAID ใต้ datastore | ฮาร์ดดิสก์ 1–2 ลูกเสีย | controller ของ host / NAS | 0 — ไม่มีใครรู้ตัว |
| 2. แยกคู่คนละ datastore | datastore ทั้งก้อนหาย (NAS / RAID ล่ม) | วาง `-01` DS-A, `-02` DS-B | วินาที – 10 นาที (ระบบสลับเอง / promote db) |
| 3. backup ทั้ง VM (image) | VM เสียทั้งเครื่อง, ลบผิด, อัปเดตแล้วบูตไม่ขึ้น | Veeam / Nakivo ไปที่เก็บที่ 3 | 15–30 นาที ต่อเครื่อง |
| 4. backup ข้อมูลนอกออฟฟิศ | ไฟไหม้ / ransomware / ทุกอย่างในห้อง server | `.bak` → FTP (ทำแล้ว) | ชั่วโมง |

### 1. RAID ใต้ datastore (กันดิสก์ลูกเดียวพัง)

- DS-A และ DS-B แต่ละก้อนต้องเป็น **RAID 10** (หรือ RAID 1 ถ้ามี 2 ลูก) — **ไม่ใช้ RAID 5** กับ DB (เขียนช้า, rebuild นานแล้วลูกที่ 2 พังซ้ำ)
- มี **hot spare** 1 ลูก หรือมีดิสก์สำรองในห้อง
- เปิดแจ้งเตือนของ controller / NAS (email หรือ SNMP เข้า Zabbix) — RAID ที่เสียไปลูกหนึ่งแล้วไม่มีใครรู้ = ไม่มี RAID
- ตั้ง patrol read / scrub เดือนละครั้ง

### 2. แยกคู่คนละ datastore (กัน datastore หายทั้งก้อน)

| datastore ที่หาย | gateway | app | DB | CI |
| --- | --- | --- | --- | --- |
| DS-A | VIP ย้ายไป gw-02 เอง | app-02 รับงานต่อ (deploy ไม่ได้จนกว่าจะกู้ manager) | promote db-02 — backup ของ db-02 หายไปด้วย ต้องเริ่มชุดใหม่ | ปกติ |
| DS-B | ใช้ gw-01 อยู่แล้ว | app-01 รับงานต่อ | db-01 ทำงานต่อ — backup ของ db-01 หาย → **รัน `mssql-backup.sh` ทันที** (ส่ง FTP ต่อได้) | หาย สร้างใหม่ |

DS-A กับ DS-B ต้องเป็นอุปกรณ์จริงคนละตัว (คนละ RAID / คนละ NAS / คนละ host) — 2 LUN บน NAS ตัวเดียวกันไม่ถือว่าแยก

### 3. backup ทั้ง VM

ชั้น 1–2 ไม่ช่วยถ้า **ข้อมูลในเครื่องเสียเอง** (อัปเดต OS แล้วบูตไม่ขึ้น, ลบไฟล์ผิด, ransomware) เพราะ RAID และคู่ของมันก็เสียตามทันที

- ใช้ **Veeam Backup & Replication Community Edition** (ฟรี สูงสุด 10 VM — เรามี 7) หรือ Nakivo Free
- เก็บไปที่ **ที่เก็บที่ 3** (NAS อีกตัว / USB disk ที่ถอดสลับได้) ห้ามเก็บบน DS-A / DS-B
- ทุกคืน 02:00 (หลัง backup DB 01:00) เก็บ 14 ชุด · เปิด immutable / แยก user ถ้าที่เก็บรองรับ (กัน ransomware ลบ backup)
- ข้อจำกัด: ESXi ต้องเป็นรุ่นที่มี license (ESXi ฟรีไม่เปิด API ให้โปรแกรม backup) — ถ้าใช้ ESXi ฟรีหรือ Proxmox ต้องเลือกเครื่องมือตาม hypervisor (Proxmox ใช้ Proxmox Backup Server ซึ่งฟรี)
- **ทดลอง restore เดือนละ 1 เครื่อง** เป็น VM ชื่อใหม่ปิดการ์ดเครือข่าย

### 4. ของที่ต้องเก็บนอก VM ให้ครบ

| เครื่อง | ของที่สร้างใหม่ไม่ได้ | ตอนนี้ | ต้องทำ |
| --- | --- | --- | --- |
| gw | cert `*.nisolution`, `secrets.env` | อยู่ทั้ง gw-01/02 | สำเนาใน password manager |
| app-01 | `stacks/erp/*.env`, `versions.env`, Swarm (manager) | อยู่เครื่องเดียว | สำเนา `.env` ใน password manager · Swarm สร้างใหม่ด้วย `30-swarm.sh` ได้ |
| db | DB, ไฟล์ upload, `/opt/data/.env` | `.bak` + FTP (ไฟล์ upload ยังไม่ส่ง FTP) | เปิด `BACKUP_FTP_FILES=1` เมื่อใช้ FTPS · `.env` ใน password manager |
| ci | `/srv/jenkins_home` (job, credential) | **ไม่มี backup** | ชั้น 3 หรือ tar รายสัปดาห์ส่งไป db backup (เข้ารหัส — มี credential) |

## ตั้งค่า VM (VMware)

| เรื่อง | ค่า | ทำไม |
| --- | --- | --- |
| ไฟล์ VM (.vmx, swap) | อยู่ datastore เดียวกับดิสก์ OS | datastore ของ OS หาย = VM หยุด ถึงดิสก์อื่นจะยังอยู่ |
| NIC | vmxnet3 | ปิด tx checksum บน overlay แล้วใน `30-swarm.sh` |
| SCSI controller | ดิสก์ OS = ตัวที่ 1 · ดิสก์ข้อมูล/backup ของ db = **PVSCSI ตัวที่ 2** | คิว I/O ของ SQL ไม่แย่งกับ OS |
| ดิสก์ข้อมูล db | Thick Provision **Eager Zeroed** | เขียนครั้งแรกไม่ช้า · กัน datastore เต็มแล้ว DB หยุด |
| ดิสก์อื่น | Thin ได้ | ต้องเฝ้า % ใช้ของ datastore (เตือนที่ 80%) |
| Memory reservation | db-01/02 และ gw จองเต็ม | กัน ballooning / host swap ทำ SQL ช้าและ keepalived หลุดจังหวะ |
| เวลา | chrony (NTP) ในเครื่อง · ปิด time sync ของ VMware Tools | log shipping และ JWT ต้องใช้เวลาตรงกัน |
| Snapshot | เก็บไม่เกิน 72 ชั่วโมง · ไม่ใช่ backup | snapshot อยู่ datastore เดียวกับ VM — datastore หายก็หายด้วย |

**ไม่แนะนำ RAID ในตัว VM (mdadm ข้าม DS-A/DS-B):** ไฟล์ .vmx และ swap ของ VM ยังอยู่ datastore เดียว — datastore นั้นหาย VM ก็หยุดอยู่ดี
และตอน datastore อีกก้อนหายแบบค้าง (APD) I/O ของ VM จะค้างหลายนาทีก่อน mdadm ตัดดิสก์ทิ้ง ได้ไม่คุ้มพื้นที่ที่ใช้เพิ่มเท่าตัว
ระบบนี้กันระดับนั้นด้วยการแยกคู่ (ชั้น 2) อยู่แล้ว

## ถ้ามี ESXi มากกว่า 1 host

**แบบที่ดีที่สุดสำหรับระบบนี้:** 2 host แต่ละ host มี datastore ของตัวเอง

| | host A | host B |
| --- | --- | --- |
| datastore | DS-A | DS-B |
| VM | gw-01, app-01, db-01 | gw-02, app-02, db-02, ci-01 |

ไม่ต้องมี shared storage หรือ vMotion — ระบบสลับกันเองที่ระดับแอป host ล่มทั้งตัว (CPU / RAM / ดิสก์) อีกฝั่งยังครบ
แต่ละ host ควรรันทุก VM ได้ตอนอีกฝั่งซ่อม: **RAM ≥ 64 GB, 8 core ขึ้นไป ต่อ host**
มี vCenter + shared storage: ตั้ง **DRS anti-affinity** คู่ gw / app / db ห้ามอยู่ host เดียวกัน

**host เดียว:** 2 datastore กันดิสก์พังได้ แต่ host ล่ม = ทั้งระบบล่ม — ชั้น 3 และ 4 คือทางกู้ · RAM host ≥ 48 GB (แนะนำ 64)

## ดิสก์ใน erp-db-01 ตอนนี้

`/srv` ของ erp-db-01 ตอนนี้เป็น iSCSI จาก NAS โดยตรง (ไม่ผ่าน datastore) — ย้ายมาเป็น VMDK บน DS-A ตามตาราง
หรือใช้ iSCSI ต่อแต่ db-01 ใช้ LUN บน NAS-A และ db-02 ใช้ LUN บน NAS-B · **ห้าม** 2 เครื่องใช้ LUN เดียวกัน
