# Migration plan: เครื่องเดิม → ERP HA

หลักการ: **เครื่องเดิมรับงานตามปกติจนถึงวันตัดระบบ** ทุกอย่างก่อนหน้านั้นทำคู่ขนานและย้อนกลับได้

| Phase | ทำอะไร | กระทบผู้ใช้ | ใช้เวลาโดยประมาณ |
|---|---|---|---|
| 0 | เช็กเครื่องเดิม + สำรองของที่เสี่ยงหาย | ไม่กระทบ | ครึ่งวัน |
| 1 | สร้าง VM template แล้ว clone เป็น 6 เครื่อง | ไม่กระทบ | ครึ่งวัน |
| 2 | vm-data-4 + ซ้อม restore DB / ไฟล์ | ไม่กระทบ | 1 วัน |
| 3 | vm-service-1/2 (Swarm) + deploy แอปชี้ DB ใหม่ | ไม่กระทบ | 1 วัน |
| 4 | gw-1/gw-2 + VIP + cert | ไม่กระทบ | ครึ่งวัน |
| 5 | vm-deploy (Jenkins) | ไม่กระทบ | ครึ่งวัน |
| 6 | ทดสอบ failover + ทดสอบแอปทุกเมนู | ไม่กระทบ | 1–2 วัน |
| 7 | ตัดระบบ | **หยุดระบบ 30–60 นาที** | นอกเวลางาน |
| 8 | เก็บกวาด | ไม่กระทบ | 1 สัปดาห์หลังตัด |

ลำดับนี้ไล่จากสิ่งที่ทุกอย่างพึ่งพา: แอปต้องมี DB ก่อน, gateway ต้องมีแอปให้ส่งต่อ, Jenkins ต้องมี cluster ให้ deploy

---

## Phase 0 — เช็กเครื่องเดิมและสำรองของที่เสี่ยงหาย

บนเครื่องเดิม:

```bash
sudo git clone https://github.com/brambroza/erp-infra /opt/erp-infra
sudo SA_PASS='รหัส sa' /opt/erp-infra/scripts/00-audit-legacy.sh
```

เอาผลไปแก้ `inventory.env`, `stacks/erp/versions.env`, path volume ใน `stacks/erp/stack.yml` (ดู runbook ข้อ 0)

สำรองของที่ถ้าหายแล้วสร้างใหม่ไม่ได้:

```bash
# 1) image ของ ticker ที่ไม่มี tag
docker tag 773b7a77bb63 nohservdoc/go-ticker-job:legacy-2026-10
docker push nohservdoc/go-ticker-job:legacy-2026-10

# 2) jenkins_home
J=$(docker ps --format '{{.Names}} {{.Image}}' | awk '/jenkins/{print $1; exit}')
docker exec "$J" tar czf /tmp/jenkins_home.tgz -C /var/jenkins_home .
docker cp "$J":/tmp/jenkins_home.tgz /root/

# 3) RabbitMQ definitions (exchange, queue, user, vhost)
docker exec rabbitmq rabbitmqctl export_definitions /tmp/defs.json
docker cp rabbitmq:/tmp/defs.json /root/rabbit-defs.json

# 4) cert
sudo tar czf /root/nginx-ssl.tgz -C /etc/nginx ssl
```

ตัดสินใจให้เสร็จใน phase นี้:

- [ ] IP ของทุกเครื่องและ VIP (เลือก IP ว่างนอกช่วง DHCP)
- [ ] ชื่อเครื่องชุดสุดท้าย (hostname = ชื่อ VM = ชื่อใน Zabbix)
- [ ] license SQL Server (`MSSQL_PID`) ตามผล `mssql.txt`
- [ ] Cloudflare เป็น proxied หรือ DNS only
- [ ] 3030 / 5678 / 10053 จะอยู่เครื่องเดิมต่อ หรือย้ายเข้า repo

---

## Phase 1 — สร้าง VM

### ห้าม clone จาก VM เครื่องเดิม

clone เครื่องเดิมดูเร็ว แต่เครื่องที่ได้จะพกของเหล่านี้มาด้วย:

- container ทุกตัวมี `restart: always` พอเปิดเครื่อง **ticker จะรันพร้อมกับตัวจริง job ทำงานซ้ำ** และแอปทุกตัวจะต่อ DB production ทันที
- IP, hostname, machine-id, SSH host key, Docker/Swarm node ID ซ้ำกับเครื่องเดิม
- disk ใหญ่เท่าเครื่องเดิม (image และ volume เก่า) และ port เปิด `0.0.0.0` แบบเดิม

ให้สร้าง **template ใหม่ที่สะอาด** แล้ว clone template นั้นแทน ส่วนข้อมูลให้ย้ายด้วย backup/restore และ rsync ใน phase 2

### สร้าง template (ทำครั้งเดียว)

1. สร้าง VM ใหม่ ติดตั้ง Ubuntu Server 24.04 LTS แบบ minimal + OpenSSH
2. ติดตั้ง guest agent: Proxmox `qemu-guest-agent` / VMware `open-vm-tools`
3. ใส่ SSH public key ของทีม แล้วปิด password login (`PasswordAuthentication no`)
4. `sudo apt update && sudo apt -y upgrade`
5. ล้างค่าที่ต้องไม่ซ้ำกันก่อนแปลงเป็น template:

```bash
sudo truncate -s0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id && sudo ln -s /etc/machine-id /var/lib/dbus/machine-id
sudo rm -f /etc/ssh/ssh_host_*
sudo cloud-init clean 2>/dev/null || true
sudo poweroff
```

6. แปลง VM นี้เป็น template

### clone เป็น 6 เครื่อง

clone template ตาม spec ใน README (vCPU / RAM / disk) แล้วบนแต่ละเครื่องหลังเปิดครั้งแรก:

```bash
sudo systemd-machine-id-setup
sudo ssh-keygen -A && sudo systemctl restart ssh
sudo vi /etc/netplan/50-cloud-init.yaml      # ใส่ IP ตาม inventory.env (static, ไม่ใช้ DHCP)
sudo netplan apply
sudo git clone https://github.com/brambroza/erp-infra /opt/erp-infra
```

แล้วรัน `scripts/00-common.sh <hostname> [--docker]` ตาม runbook ข้อ 1
vm-data-4 ให้เพิ่ม disk แยก 2 ลูก (data และ backup) mount ที่ `/srv` และ `/srv/mssql/backup`

---

## Phase 2 — vm-data-4 (ทำก่อนเพราะทุกอย่างพึ่ง DB)

```bash
sudo /opt/erp-infra/scripts/20-data.sh        # รอบแรก: สร้าง /opt/data/.env
sudo vi /opt/data/.env
sudo /opt/erp-infra/scripts/20-data.sh        # รอบสอง: start SQL Server, Redis, RabbitMQ, NFS
```

### SQL Server: ซ้อม restore

บนเครื่องเดิม:

```bash
docker exec -e SQLCMDPASSWORD="$SA_PASS" sqlserverhighperf /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -Q \
  "BACKUP DATABASE [CRMDB] TO DISK='/var/opt/mssql/data/CRMDB_full.bak' WITH COMPRESSION, CHECKSUM, INIT"
docker cp sqlserverhighperf:/var/opt/mssql/data/CRMDB_full.bak .
scp CRMDB_full.bak root@vm-data-4:/srv/mssql/backup/
```

บน vm-data-4:

```bash
/opt/erp-infra/data/dc.sh exec -e SQLCMDPASSWORD="$SA" mssql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -Q \
  "RESTORE FILELISTONLY FROM DISK='/var/opt/mssql/backup/CRMDB_full.bak'"
# แล้ว RESTORE ... WITH MOVE ตามชื่อ logical file (runbook ข้อ 2)
```

- login ของแอป: สร้าง login เดิมบนเครื่องใหม่ แล้วผูก user ด้วย `ALTER USER [x] WITH LOGIN = [x];`
- จดเวลาที่ backup + copy + restore ใช้ เพื่อประเมินเวลาหยุดระบบใน phase 7
- ถ้า DB เป็น Express edition ให้ตัด `WITH COMPRESSION` ออก

### ไฟล์ Data API (volume ของ go-crmapi24)

```bash
# จากเครื่องเดิม (path ดูจาก mounts.txt)
sudo rsync -aH --numeric-ids <path volume เดิม>/ root@vm-data-4:/srv/nfs/erp-files/
```

รอบนี้ใช้เวลาตามขนาดไฟล์ (1.7 GB) รอบหลัง ๆ จะ copy เฉพาะไฟล์ที่เปลี่ยน

### RabbitMQ

```bash
scp /root/rabbit-defs.json root@vm-data-4:/tmp/
# vm-data-4
docker cp /tmp/rabbit-defs.json data-rabbitmq-1:/tmp/defs.json
/opt/erp-infra/data/dc.sh exec rabbitmq rabbitmqctl import_definitions /tmp/defs.json
```

### Redis

ส่วนใหญ่เก็บแค่ cache และ session ไม่ต้องย้าย (ผู้ใช้ login ใหม่ครั้งเดียวตอนตัดระบบ)
ถ้าเก็บข้อมูลที่ต้องอยู่ถาวร ให้ copy `dump.rdb` ตอนตัดระบบหลังหยุด Redis เดิม

---

## Phase 3 — vm-service-1 / vm-service-2

```bash
# vm-service-1
sudo /opt/erp-infra/scripts/30-swarm.sh init
# vm-service-2
sudo /opt/erp-infra/scripts/30-swarm.sh join <token>
# vm-service-1
docker node update --label-add role=app vm-service-2
```

env ของแต่ละแอป: เอาจาก `env/*.env` ใน audit แล้วเปลี่ยน host ของ DB/Redis/RabbitMQ เป็น vm-data-4

```bash
cd /opt/erp-infra/stacks/erp
sudo install -m 600 -o deploy /path/to/audit/env/go-crmapi24.env erpapi.env    # แล้วแก้ host
sudo install -m 600 -o deploy /path/to/audit/env/go-chat-api.env  chat-api.env
sudo install -m 600 -o deploy /path/to/audit/env/go-ticker-job.env ticker.env
vi versions.env          # tag จริงจาก image-of-each.txt และ TICKER_REPLICAS=0
docker login
./deploy-stack.sh
```

ทดสอบตรงที่เครื่อง (ยังไม่ผ่าน gateway):

```bash
curl -I http://vm-service-1:8284/      # erpapp
curl -I http://vm-service-2:6334/      # erpapi
```

**TICKER_REPLICAS ต้องเป็น 0 จนถึง phase 7** ไม่อย่างนั้น job รันซ้ำกับเครื่องเดิม

---

## Phase 4 — gw-1 / gw-2 + VIP

```bash
# จากเครื่องเดิม: copy cert
for gw in gw-1 gw-2; do scp /root/nginx-ssl.tgz root@$gw:/root/ && ssh root@$gw 'mkdir -p /etc/nginx && tar xzf /root/nginx-ssl.tgz -C /etc/nginx'; done

# gw-1 และ gw-2
sudo cp /opt/erp-infra/secrets.env.example /opt/erp-infra/secrets.env && sudo vi /opt/erp-infra/secrets.env
sudo /opt/erp-infra/scripts/10-gateway.sh gw-1       # บน gw-2 ใช้ gw-2
```

ทดสอบโดยยังไม่เปลี่ยน router: บนเครื่องของผู้ทดสอบ แก้ `/etc/hosts` (Windows: `C:\Windows\System32\drivers\etc\hosts`)

```
192.168.88.100  erp.nisolution.co.th api.nisolution.co.th
```

แล้วเปิด `https://erp.nisolution.co.th` จะได้ระบบใหม่ ส่วนผู้ใช้คนอื่นยังใช้เครื่องเดิม

---

## Phase 5 — vm-deploy (Jenkins)

```bash
# วาง jenkins_home เดิม
sudo mkdir -p /srv/jenkins_home && sudo tar xzf /root/jenkins_home.tgz -C /srv/jenkins_home && sudo chown -R 1000:1000 /srv/jenkins_home
sudo /opt/erp-infra/scripts/40-jenkins.sh
```

- เพิ่ม credential `swarm-manager-ssh` (key ของ user `deploy` บน vm-service-1)
- สร้าง job `erp-deploy` จาก `jenkins/Jenkinsfile.deploy`
- ปรับ job build เดิมให้ push tag เลข build แล้วเรียก `erp-deploy` (ตัวอย่าง `jenkins/Jenkinsfile.build.example`)
- **ปิด job deploy เดิมบน Jenkins ตัวเก่า** ระหว่างนี้ ไม่อย่างนั้นมีคน deploy ไปเครื่องเดิมโดยไม่รู้ตัว

ทดสอบ: deploy erpapp tag เดิมซ้ำ 1 รอบ ต้องผ่านและไม่มี downtime

---

## Phase 6 — ทดสอบ

- [ ] ตารางทดสอบ failover ใน runbook ข้อ 6 ผ่านทุกข้อ
- [ ] login, เมนูหลัก, upload/download ไฟล์, แจ้งเตือน (SignalR), chat, LINE webhook
- [ ] ผู้ใช้ 2 คนต่อคนละเครื่อง (ดู `upstream_addr` ใน log ของ gw) แล้วส่งแจ้งเตือนหากันได้ ถ้าไม่ได้ = ยังไม่ได้ทำ Redis backplane ในโค้ด
- [ ] backup cron บน vm-data-4 ทำงานและ restore ลง DB ทดสอบได้
- [ ] Zabbix เห็นครบ 6 เครื่อง

ถ้าโค้ดยังไม่มี Redis backplane / socket.io adapter ให้ตัดระบบแบบเครื่องเดียวก่อน:
`docker node update --availability drain vm-service-2` แล้วค่อยเปิดเครื่องที่สองหลังแก้โค้ด

---

## Phase 7 — ตัดระบบ (นอกเวลางาน)

ลดเวลาหยุดระบบด้วย **full backup ล่วงหน้า + differential ตอนตัด**

**ช่วงเช้าวันตัด (ระบบยังทำงาน):**

```sql
-- เครื่องเดิม
BACKUP DATABASE [CRMDB] TO DISK='/var/opt/mssql/data/CRMDB_full.bak' WITH COMPRESSION, CHECKSUM, INIT;
-- vm-data-4 (ทับ DB ทดสอบ)
RESTORE DATABASE [CRMDB] FROM DISK='/var/opt/mssql/backup/CRMDB_full.bak'
WITH MOVE ..., NORECOVERY, REPLACE;
```

ระหว่างนี้ห้ามมี full backup อื่นบนเครื่องเดิม (ให้ปิด backup job อื่นชั่วคราว) ไม่อย่างนั้น differential จะต่อกันไม่ได้

**ช่วงตัดระบบ:**

| เวลา | ทำอะไร |
|---|---|
| T+0 | ประกาศปิดปรับปรุง หยุด go-crmapi24, go-chat-api, go-ticker-job, go-crmapp24 บนเครื่องเดิม (`docker stop`) |
| T+2 | `BACKUP DATABASE [CRMDB] TO DISK='...CRMDB_diff.bak' WITH DIFFERENTIAL, COMPRESSION, CHECKSUM` |
| T+5 | copy diff ไป vm-data-4 แล้ว `RESTORE DATABASE [CRMDB] FROM DISK='...CRMDB_diff.bak' WITH RECOVERY` |
| T+5 | คู่ขนาน: `rsync` ไฟล์ Data API รอบสุดท้าย, เช็ก queue RabbitMQ เดิมว่าง |
| T+15 | vm-service-1: `TICKER_REPLICAS=1` ใน versions.env แล้ว `./deploy-stack.sh` |
| T+20 | ทดสอบผ่าน `/etc/hosts` ชี้ VIP: login, ข้อมูลล่าสุดตรง, upload, แจ้งเตือน |
| T+30 | router: เปลี่ยน port forward 80/443 ไปที่ VIP · DNS ภายในชี้ VIP |
| T+35 | ทดสอบจากข้างนอก (มือถือ 4G) และจากในออฟฟิศ |
| T+45 | ประกาศเปิดระบบ |

**ย้อนกลับ (ถ้ามีปัญหาก่อนประกาศเปิด):** router ชี้กลับเครื่องเดิม → `docker start` container เดิม
ข้อมูลที่เขียนบนระบบใหม่หลังเปิดจะไม่อยู่บนเครื่องเดิม จึงต้องตัดสินใจย้อนกลับก่อนเปิดให้ผู้ใช้ใช้งาน

---

## Phase 8 — หลังตัดระบบ

- วันที่ 1–7: เฝ้า Zabbix, log ของ gw และ `docker service ps` · container เดิมเก็บไว้แต่ห้าม start
- ปิด nginx เดิม · บริการ 3030 / 5678 / 10053 ให้ฟัง IP ภายในและเปิดให้ gw เข้าถึง (runbook ข้อ 7)
- หลัง 7 วัน: ลบ container แอป, SQL Server, Redis, RabbitMQ, Konga, Postgres บนเครื่องเดิม
- เปิด backup job ปกติกลับมา และซ้อม restore เดือนละครั้ง
