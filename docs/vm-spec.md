# Spec VM และการวางบน 2 datastore

ใช้กับแผน 2 (มี erp-db-02 — ดู [infra-diagram-plan2.svg](infra-diagram-plan2.svg)) · ถ้ายังไม่ทำแผน 2 ข้าม erp-db-02 ได้ ที่เหลือใช้ได้เหมือนเดิม
ค่าที่วัดจริงและสูตรคำนวณอยู่ใน [architecture.md](architecture.md#resource)

## หลักการวาง

ระบบนี้ทำ HA ที่ระดับแอปอยู่แล้ว (VRRP ของ gateway, Swarm 2 เครื่อง, primary/standby ของ DB)
เป้าหมายของ 2 datastore คือ **datastore ลูกไหนพังลูกเดียว ระบบยังเหลือครบทุกบทบาท**

1. **แยกคู่:** เครื่อง `-01` อยู่ DS-A, เครื่อง `-02` อยู่ DS-B เสมอ
2. **backup ห้ามอยู่ datastore เดียวกับข้อมูลที่มันสำรอง:** ดิสก์ backup ของ db-01 อยู่ DS-B, ของ db-02 อยู่ DS-A
3. **เครื่องเดี่ยว (erp-ci-01, Zabbix) อยู่ฝั่งตรงข้าม primary DB (DS-B):** DS-A พังเมื่อไหร่ Zabbix ยังอยู่แจ้งเตือนได้
4. **2 datastore ต้องเป็นของจริงคนละชิ้น:** คนละ NAS / คนละ RAID / คนละ host — ถ้าเป็น 2 LUN บน NAS ตัวเดียวกัน NAS ล่มก็หายทั้งคู่ (แบ่งไว้ได้แค่ช่วยเรื่องพื้นที่)

## Spec ต่อเครื่อง

| VM | IP | vCPU | RAM | ดิสก์ OS | ดิสก์ข้อมูล | ดิสก์ backup |
| --- | --- | ---: | ---: | --- | --- | --- |
| erp-gw-01 | .101 | 2 | 2 GB | 20 GB · **DS-A** | – | – |
| erp-gw-02 | .102 | 2 | 2 GB | 20 GB · **DS-B** | – | – |
| erp-app-01 | .111 | 4 | 8 GB | 40 GB · **DS-A** | – | – |
| erp-app-02 | .112 | 4 | 8 GB | 40 GB · **DS-B** | – | – |
| erp-db-01 | .12 | 4 (1 socket × 4 core) | 8 GB (จองเต็ม) | 30 GB · **DS-A** | 80 GB `/srv` · **DS-A** | 100 GB `/srv/mssql/backup` · **DS-B** |
| erp-db-02 (แผน 2) | .13 | 4 (1 socket × 4 core) | 8 GB (จองเต็ม) | 30 GB · **DS-B** | 80 GB `/srv` · **DS-B** | 100 GB `/srv/mssql/backup` · **DS-A** |
| erp-ci-01 | .131 | 2 | 4 GB | 40 GB · **DS-B** | – | – |
| **รวม** | | **22** | **40 GB** | | | |

เหตุผลของตัวเลขที่เปลี่ยนจาก architecture.md:

- **gw 1 → 2 vCPU:** TLS ของทุก request ผ่าน gateway ตัวเดียว (อีกตัวรอ) และ keepalived ต้องได้ CPU ตรงเวลา ไม่งั้น VIP สลับเอง
- **db 4 → 8 GB:** SQL Server ~2 GB + Redis 0.5 + RabbitMQ 0.5 + OS + page cache ของ NFS · ตั้ง `MSSQL_MEMORY_LIMIT_MB=5120` และลบ 3 บรรทัด `REDIS_*`/`RABBITMQ_MEM_LIMIT` ใน `/opt/data/.env` (ดูคอมเมนต์ใน `.env.example`)
- **ดิสก์ข้อมูล 60 → 80 GB:** แผน 2 ใช้ FULL recovery (มี log file + log backup) และ Express รับ DB ได้ถึง 10 GB/DB — เผื่อให้โตถึงเพดานได้โดยไม่ต้องขยายดิสก์
- **ดิสก์ backup 60 → 100 GB:** full 7 วัน (ถ้า DB โตถึง 10 GB ≈ 70 GB) + log backup + ไฟล์รอส่ง FTP (`/srv/mssql/offsite`)
- **app / ci:** เท่าเดิม — app แต่ละเครื่องต้องรับโหลดทั้งหมดคนเดียวได้ (วัดได้ 4.3 GB จาก 8 GB)

### ⚠ SQL Server Express กับจำนวน socket

Express ใช้ CPU ได้ **"1 socket หรือ 4 core แล้วแต่อันไหนน้อยกว่า"**
ถ้าตั้ง VM เป็น 4 vCPU แบบ 4 socket × 1 core (ค่าเริ่มต้นของ VMware บางรุ่น) SQL Server จะใช้ได้ **core เดียว**
ต้องตั้ง **Cores per socket = 4** · ตรวจบนเครื่องที่มีอยู่:

```bash
sudo /opt/erp-infra/data/dc.sh exec -T -e SQLCMDPASSWORD="$(sudo grep -oP '^MSSQL_SA_PASSWORD=\K.*' /opt/data/.env)" mssql \
  /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -Q \
  "SELECT cpu_count, socket_count, cores_per_socket FROM sys.dm_os_sys_info; SELECT COUNT(*) AS cpu_ใช้ได้ FROM sys.dm_os_schedulers WHERE status='VISIBLE ONLINE'"
```

`cpu_ใช้ได้` ต้องเท่ากับ 4 · ถ้าได้ 1 ให้ปิด VM แล้วแก้ Cores per socket

## ขนาด datastore

| | DS-A | DS-B |
| --- | --- | --- |
| VM | gw-01 20 · app-01 40 · db-01 30+80 · backup ของ db-02 100 | gw-02 20 · app-02 40 · db-02 30+80 · backup ของ db-01 100 · ci-01 40 |
| รวมดิสก์ | 270 GB | 310 GB |
| swap ของ VM (RAM ที่ไม่ได้จอง) | ~10 GB | ~14 GB |
| เผื่อ snapshot / โต 30% | | |
| **ขั้นต่ำที่ควรมี** | **400 GB** | **450 GB** |

ถ้ายังไม่ทำแผน 2: DS-A ไม่มี backup ของ db-02 (−100) และ DS-B ไม่มี db-02 (−110)

## ตั้งค่า VM (VMware)

| เรื่อง | ค่า | ทำไม |
| --- | --- | --- |
| NIC | vmxnet3 | มีปัญหา checksum บน overlay ที่แก้ไว้แล้วใน `30-swarm.sh` |
| SCSI controller | ดิสก์ OS = ตัวที่ 1, ดิสก์ข้อมูล/backup ของ db = **PVSCSI แยกตัวที่ 2** | คิว I/O ของ SQL ไม่แย่งกับ OS |
| ดิสก์ข้อมูล db | Thick Provision **Eager Zeroed** | เขียนครั้งแรกไม่ช้า · กัน datastore เต็มแล้ว DB หยุด |
| ดิสก์อื่น | Thin ได้ | ประหยัดพื้นที่ — แต่ต้องเฝ้า % ใช้ของ datastore |
| Memory reservation | db-01 / db-02 จองเต็ม · gw จองเต็ม (2 GB) | กัน ballooning / host swap ทำ SQL ช้าและ keepalived หลุดจังหวะ |
| เวลา | chrony (NTP) ในเครื่อง · ปิด time sync ของ VMware Tools | log shipping และ JWT ต้องใช้เวลาตรงกัน |
| Snapshot | เก็บไม่เกิน 72 ชั่วโมง · ห้ามทำ snapshot เป็น backup ของ db | snapshot โตเรื่อย ๆ และทำ I/O ช้าลง · backup จริงคือ `.bak` + FTP |
| Guest tools | open-vm-tools | shutdown/IP จาก vCenter ได้ |

## ถ้ามี ESXi มากกว่า 1 host

**แบบที่ดีที่สุดสำหรับระบบนี้:** 2 host แต่ละ host มี datastore ของตัวเอง

| | host A | host B |
| --- | --- | --- |
| datastore | DS-A | DS-B |
| VM | gw-01, app-01, db-01 | gw-02, app-02, db-02, ci-01, Zabbix |

ไม่ต้องมี shared storage หรือ vMotion — ระบบสลับกันเองที่ระดับแอป host ไหนล่มทั้งตัว (CPU / RAM / ดิสก์) อีกฝั่งยังครบ
แต่ละ host ต้องรันงานของอีกฝั่งได้ในอนาคต (ย้ายเครื่องตอนซ่อม): **RAM ≥ 64 GB, 8 core ขึ้นไป ต่อ host**

ถ้ามี vCenter + shared storage: ตั้ง **DRS anti-affinity** ให้คู่ gw-01/02, app-01/02, db-01/02 ห้ามอยู่ host เดียวกัน

**ถ้ามี host เดียว:** แบ่ง 2 datastore ยังช่วยเรื่องดิสก์พัง แต่ host ล่ม = ทั้งระบบล่ม — ต้องมี backup นอกเครื่อง (FTP) และแผนกู้บนเครื่องอื่น
host เดียวต้องมี **RAM ≥ 48 GB** (VM 40 + ESXi) แนะนำ 64 GB

## ดิสก์ใน erp-db-01 ตอนนี้

`/srv` ของ erp-db-01 ตอนนี้เป็น iSCSI จาก NAS โดยตรง (ไม่ผ่าน datastore)
เมื่อแบ่ง 2 datastore: ย้ายมาเป็นดิสก์ VMDK บน DS-A ตามตาราง หรือใช้ iSCSI ต่อแต่ db-01 ใช้ LUN บน NAS-A และ db-02 ใช้ LUN บน NAS-B — **ห้าม** ให้ 2 เครื่องใช้ LUN เดียวกัน
