# Runbook

## 0. เช็กเครื่องเดิมก่อน (ไม่กระทบระบบ)

```bash
sudo git clone https://github.com/brambroza/erp-infra /opt/erp-infra
sudo SA_PASS='รหัส sa' /opt/erp-infra/scripts/00-audit-legacy.sh
```

script อ่านอย่างเดียว ได้ไฟล์ `/root/legacy-audit-<วันที่>.tar.gz` ใช้ข้อมูลในนั้นแก้ค่าใน repo:

| ดูจากไฟล์ | เอาไปแก้ที่ |
|---|---|
| `host.txt` (IP, interface) | `inventory.env` (`LEGACY_IP`, `IFACE`) |
| `image-of-each.txt` | `stacks/erp/versions.env` (tag ที่รันอยู่จริง) |
| `mounts.txt`, `volume-sizes.txt` | path ของ volume erpapi ใน `stacks/erp/stack.yml` และขนาด disk ของ erp-db-01 |
| `env/*.env` | `stacks/erp/*.env` (เปลี่ยน host ของ DB/Redis/RabbitMQ เป็น erp-db-01) |
| `mssql.txt`, `redis.txt`, `rabbitmq.txt` | tag image ใน `data/compose.yml` และ `MSSQL_PID` |
| `legacy-ports.txt` | ยืนยันว่า 3030 / 5678 / 10053 คืออะไร |
| `docker-stats.txt` | ยืนยัน spec RAM ของแต่ละ VM |

## 0.1 เตรียม

- เลือก IP ที่ว่างจริงแล้วแก้ `inventory.env`
- clone repo ไว้ที่ `/opt/erp-infra` บนทุกเครื่องใหม่: `sudo git clone https://github.com/brambroza/erp-infra /opt/erp-infra`
- บนเครื่องเดิม **ก่อนแตะอะไร**:
  ```bash
  # image ของ ticker ที่ไม่มี tag
  docker tag 773b7a77bb63 nohservdoc/go-ticker-job:legacy-2026-10
  docker push nohservdoc/go-ticker-job:legacy-2026-10

  # เก็บ env ของ container เดิม
  /opt/erp-infra/scripts/export-env.sh go-crmapi24 > erpapi.env
  /opt/erp-infra/scripts/export-env.sh go-chat-api  > chat-api.env
  /opt/erp-infra/scripts/export-env.sh go-ticker-job > ticker.env

  # เก็บ mount และ RabbitMQ definitions
  docker inspect -f '{{.Name}} {{json .Mounts}}' $(docker ps -q) > mounts.json
  docker exec rabbitmq rabbitmqctl export_definitions /tmp/defs.json && docker cp rabbitmq:/tmp/defs.json .
  ```

## 1. ทุกเครื่อง

```bash
sudo /opt/erp-infra/scripts/00-common.sh erp-gw-01                     # gateway ไม่ต้องมี docker
sudo /opt/erp-infra/scripts/00-common.sh erp-gw-02
sudo /opt/erp-infra/scripts/00-common.sh erp-app-01 --docker
sudo /opt/erp-infra/scripts/00-common.sh erp-app-02 --docker
sudo /opt/erp-infra/scripts/00-common.sh erp-db-01    --docker
sudo /opt/erp-infra/scripts/00-common.sh erp-ci-01   --docker
```

## 2. erp-db-01

```bash
sudo /opt/erp-infra/scripts/20-data.sh          # รอบแรกจะสร้าง /opt/data/.env ให้แก้รหัสผ่าน
sudo vi /opt/data/.env
sudo /opt/erp-infra/scripts/20-data.sh          # รอบสอง start container
```

restore SQL Server จากไฟล์ `.bak` ของเครื่องเดิม:

```sql
RESTORE FILELISTONLY FROM DISK='/var/opt/mssql/backup/crm.bak';
RESTORE DATABASE [CRMDB] FROM DISK='/var/opt/mssql/backup/crm.bak'
WITH MOVE 'CRMDB' TO '/var/opt/mssql/data/CRMDB.mdf',
     MOVE 'CRMDB_log' TO '/var/opt/mssql/data/CRMDB_log.ldf';
```

copy ไฟล์ Data API (volume ของ go-crmapi24) จากเครื่องเดิม:

```bash
sudo rsync -aH --numeric-ids <path volume เดิม>/ root@erp-db-01:/srv/nfs/erp-files/
```

## 3. Swarm

```bash
# erp-app-01
sudo /opt/erp-infra/scripts/30-swarm.sh init
# erp-app-02 (ใช้ token จากคำสั่งบน)
sudo /opt/erp-infra/scripts/30-swarm.sh join SWMTKN-1-xxxx
# erp-app-01
docker node update --label-add role=app erp-app-02
```

deploy ครั้งแรก (บน erp-app-01):

```bash
cd /opt/erp-infra/stacks/erp
for s in erpapi chat-api ticker; do sudo install -m 600 $s.env.example $s.env; done   # แล้วใส่ค่าจริง
vi versions.env                                                                       # ใส่ tag ของแต่ละ image
docker login
./deploy-stack.sh
docker stack ps erp --format 'table {{.Name}}\t{{.Node}}\t{{.CurrentState}}'
```

> ระหว่างที่เครื่องเดิมยังรัน ticker อยู่ ให้ตั้ง `TICKER_REPLICAS=0` ใน versions.env ก่อน ห้ามรัน ticker พร้อมกัน 2 ที่

## 4. Gateway

```bash
# จากเครื่องเดิม copy wildcard cert ไป gw ทั้งสอง
for gw in erp-gw-01 erp-gw-02; do
  ssh root@$gw 'mkdir -p /etc/nginx/ssl && chmod 700 /etc/nginx/ssl'
  scp /etc/nginx/ssl/{fullchain_nisolution.crt,star_nisolution_co_th.key,ca-bundle.crt} root@$gw:/etc/nginx/ssl/
done

# erp-gw-01 และ erp-gw-02
sudo cp /opt/erp-infra/secrets.env.example /opt/erp-infra/secrets.env && sudo vi /opt/erp-infra/secrets.env
sudo /opt/erp-infra/scripts/10-gateway.sh erp-gw-01     # บน erp-gw-02 ใช้ erp-gw-02
ip -br addr show                                    # เครื่องที่ถือ VIP จะเห็น VIP
```

แก้ config ทีหลัง: แก้ใน repo บน erp-gw-01 แล้วรัน `scripts/11-sync-gw.sh` (เพิ่ม `--cert` เมื่อเปลี่ยน cert)

## 5. erp-ci-01

```bash
sudo /opt/erp-infra/scripts/40-jenkins.sh
```

ย้าย `jenkins_home` จากเครื่องเดิมมาไว้ที่ `/srv/jenkins_home` ก่อน start ถ้าต้องการเก็บ job เดิม
เพิ่ม credential `swarm-manager-ssh` (SSH key ของ user `deploy` บน erp-app-01) แล้วสร้าง job จาก `jenkins/Jenkinsfile.deploy`

## 6. ทดสอบก่อนเปิดใช้จริง

ยิง request ต่อเนื่องจากเครื่องข้างนอกระหว่างทดสอบทุกข้อ:

```bash
while true; do printf '%s ' "$(curl -s -o /dev/null -w '%{http_code}' https://api.nisolution.co.th/)"; sleep 0.5; done
```

| ทดสอบ | คำสั่ง | ผลที่ถูกต้อง |
|---|---|---|
| Nginx บน erp-gw-01 ล่ม | `erp-gw-01: sudo systemctl stop nginx` | VIP ย้ายไป erp-gw-02 ภายใน 5 วินาที และกลับมาเมื่อ start ใหม่ |
| erp-gw-01 ดับทั้งเครื่อง | ปิด VM erp-gw-01 | error ไม่เกิน 2–3 ครั้งแล้วกลับเป็นปกติ |
| erp-app-02 ออกจาก cluster | `docker node update --availability drain erp-app-02` | ระบบตอบปกติ แล้วคืนด้วย `--availability active` |
| erp-app-01 ดับ | ปิด VM | แอปยังตอบผ่าน erp-app-02 และ ticker ย้ายไป erp-app-02 |
| Deploy เวอร์ชันเสีย | deploy tag ที่ health ไม่ผ่าน | Swarm rollback และ job Jenkins fail |
| Restore DB | restore `.bak` ล่าสุดลง DB ทดสอบ | restore ผ่านและข้อมูลตรง |

## 7. Cutover

1. หยุด go-crmapi24, go-chat-api และ go-ticker-job บนเครื่องเดิม
2. backup → restore SQL รอบสุดท้าย และ rsync ไฟล์ Data API รอบสุดท้าย
3. รอให้ queue ของ RabbitMQ ว่าง แล้ว import definitions เข้า erp-db-01
4. ตั้ง `TICKER_REPLICAS=1` แล้ว `./deploy-stack.sh`
5. เปลี่ยน port forward 80/443 บน Router ให้ชี้ไปที่ VIP
6. ไล่ทดสอบตามตารางข้อ 6
7. บนเครื่องเดิม: เปิด port 3030, 5678, 10053 ให้ erp-gw-01/erp-gw-02 เข้าถึง แล้วปิด nginx ตัวเดิม เก็บ container เดิมไว้ 1 สัปดาห์เผื่อย้อนกลับ

## Rollback

- **ย้อนเวอร์ชันแอป:** แก้ tag ใน `versions.env` กลับเป็นค่าเดิม แล้ว `./deploy-stack.sh`
- **ย้อนทั้งระบบระหว่าง cutover:** เปลี่ยน port forward บน Router กลับไปเครื่องเดิม แล้ว start container เดิม

## Monitoring (Zabbix 192.168.88.21)

`00-common.sh` ลง zabbix-agent ให้ทุกเครื่องแล้ว · `scripts/50-zabbix.sh` เพิ่มจุดเช็กเฉพาะตามบทบาทเครื่อง (ตอนนี้: gateway)

### Gateway (erp-gw-01 / erp-gw-02)

1. บนแต่ละ gw: pull repo → `sudo scripts/10-gateway.sh $(hostname)` (เปิด `/basic_status` ที่ 127.0.0.1:8081) → `sudo scripts/50-zabbix.sh`
2. Zabbix: Import `monitoring/zabbix/template-erp-gateway.yaml` (ลิงก์ Linux + Nginx by Zabbix agent มาให้แล้ว)
3. เพิ่ม host `erp-gw-01` / `erp-gw-02` (ชื่อต้องตรงกับ hostname) interface Agent = IP ของเครื่อง port 10050 ใส่ template `ERP Gateway`
4. trigger ข้ามเครื่อง (สร้างที่ host erp-gw-01 ครั้งเดียว) ระดับ Disaster:
   `last(/erp-gw-01/erp.vip)+last(/erp-gw-02/erp.vip)<>1` — ไม่มีใครถือ VIP หรือถือทั้งสองเครื่อง (split brain)

### Swarm (erp-app-01 / erp-app-02)

1. บนแต่ละเครื่อง: pull repo → `sudo scripts/50-zabbix.sh` (ลง UserParameter + sudoers ให้ user zabbix เรียกได้เฉพาะ `/usr/local/bin/erp-zbx.sh`)
2. Zabbix: Import `monitoring/zabbix/template-erp-swarm.yaml`
3. host `erp-app-01` ใส่ `ERP Swarm node` + `ERP Swarm manager` · host `erp-app-02` ใส่ `ERP Swarm node`
4. ระหว่าง drain เครื่องเพื่อซ่อม trigger "ไม่มี container ของ erp" จะเด้ง — ปิดชั่วคราวได้ (Maintenance)

### Data (erp-db-01)

1. บนเครื่อง: pull repo → `sudo scripts/50-zabbix.sh` (ติดตั้ง cron `/etc/cron.d/erp-zbx-db` เก็บค่าทุกนาทีลง `/var/lib/erp-zbx/db.env` — ไฟล์นี้ไม่มีรหัสผ่าน)
2. Zabbix: Import `monitoring/zabbix/template-erp-data.yaml` → host `erp-db-01` (192.168.88.12:10050) ใส่ `ERP Data`
3. ดูค่าทั้งหมดบนเครื่อง: `cat /var/lib/erp-zbx/db.env`

### CI (erp-ci-01) และการตรวจจากมุมผู้ใช้

- Import `template-erp-ci.yaml` → host `erp-ci-01` (192.168.88.131:10050) ใส่ `ERP CI` · ไม่ต้องรันสคริปต์บนเครื่อง
- Import `template-erp-web.yaml` → สร้าง host `erp-vip` **ไม่ต้องมี interface** ใส่ `ERP Web` (Zabbix server ยิง https://192.168.88.100 พร้อม Host header ทุกนาที)

### แจ้งเตือนเข้า Slack

1. Slack: สร้าง channel เช่น `#erp-alert` แล้ว `/invite @<bot>` (ใช้ bot ตัวเดียวกับ Jenkins ได้ ต้องมี scope `chat:write`)
2. Zabbix: Alerts (6.0: Administration) → Media types → **Slack** → ใส่ `bot_token` → Enabled
3. Administration → General → Macros: `{$ZABBIX.URL}` = URL หน้าเว็บ Zabbix (ลิงก์ในข้อความ)
4. Users → Admin (หรือ user ของทีม) → Media → Add: Type Slack, Send to `#erp-alert`, Use if severity: Average, High, Disaster
5. Alerts → Actions → Trigger actions → Create: เงื่อนไข Host group = `ERP-HA` และ Trigger severity ≥ Average · Operations ส่งหา user group ผ่าน Slack · เปิด Recovery operations
6. ทดสอบ: Media types → Slack → Test
