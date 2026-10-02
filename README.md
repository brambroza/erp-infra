# erp-infra

Infrastructure as code ของระบบ ERP (nisolution.co.th) แบบ High Availability

```
ผู้ใช้ → Router (443) → VIP → gw-1 (MASTER) / gw-5 (BACKUP)
                              ↓
              vm-service-1 (Swarm manager) + vm-service-2 (worker)
              erpapp · erpapi · chat-api · ticker
                              ↓
              vm-data-4: SQL Server · Redis · RabbitMQ · NFS (Data API files)

vm-jenkins → ssh → vm-service-1 → rolling update ทีละเครื่อง
```

รายละเอียด diagram, flow และ resource อยู่ใน [docs/architecture.md](docs/architecture.md)
ขั้นตอนติดตั้ง ทดสอบ และย้ายระบบอยู่ใน [docs/runbook.md](docs/runbook.md)

## เครื่องทั้งหมด

| VM | หน้าที่ | Spec แนะนำ (vCPU / RAM / Disk) |
|---|---|---|
| gw-1 | Nginx + keepalived (MASTER) | 1 / 2 GB / 20 GB |
| gw-5 | Nginx + keepalived (BACKUP) | 1 / 2 GB / 20 GB |
| vm-service-1 | Swarm manager: erpapp, erpapi, chat-api, ticker | 4 / 8 GB / 40 GB |
| vm-service-2 | Swarm worker: erpapp, erpapi, chat-api, ticker สำรอง | 4 / 8 GB / 40 GB |
| vm-data-4 | SQL Server, Redis, RabbitMQ, NFS | 4 / 4–8 GB / 60 GB + backup 60 GB |
| vm-jenkins | Jenkins build + deploy | 2 / 4 GB / 40 GB |

## โครงสร้าง repo

```
erp-infra/
├── inventory.env              # hostname / IP ทั้งหมด (แก้ที่นี่ที่เดียว)
├── secrets.env.example        # VRRP_PASS → copy เป็น secrets.env
├── scripts/
│   ├── 00-audit-legacy.sh     # เครื่องเดิม: เก็บข้อมูลก่อนย้าย (อ่านอย่างเดียว)
│   ├── 00-common.sh           # ทุกเครื่อง: hostname, hosts, sysctl, ufw, zabbix-agent, docker
│   ├── 10-gateway.sh          # gw-1 / gw-5: nginx + keepalived
│   ├── 11-sync-gw.sh          # รันบน gw-1: sync config (+cert) ไป gw-5
│   ├── 20-data.sh             # vm-data-4: compose + NFS + backup cron
│   ├── 30-swarm.sh            # vm-service-1 init / vm-service-2 join
│   ├── 40-jenkins.sh          # vm-jenkins: Jenkins + docker cli
│   └── export-env.sh          # ดึง env ของ container เดิมออกมาเป็นไฟล์
├── gateway/
│   ├── keepalived/            # keepalived.conf.tpl, gw-notify.sh
│   └── nginx/
│       ├── upstreams.conf.tpl
│       ├── conf.d/            # 05-common, 10-http, 11-healthz, 20-erp, 21-api, 22-app, 23-n8n, 24-zabbix
│       └── infra/             # ssl.conf, proxy.conf, ws.conf
├── data/                      # compose.yml, dc.sh, .env.example, mssql-backup.sh
├── stacks/erp/                # stack.yml, versions.env, *.env.example, deploy-stack.sh, wait-converge.sh
├── jenkins/                   # Dockerfile, compose.yml, dc.sh, Jenkinsfile.deploy, Jenkinsfile.build.example
└── docs/                      # architecture.md, runbook.md
```

## ลำดับติดตั้งแบบย่อ

0. เครื่องเดิม: `sudo SA_PASS=... scripts/00-audit-legacy.sh` เก็บข้อมูลก่อน (อ่านอย่างเดียว)
1. แก้ `inventory.env`, `versions.env` และ path volume ตามผล audit แล้ว clone repo ไว้ที่ `/opt/erp-infra` บนทุกเครื่องใหม่
2. ทุกเครื่อง: `sudo scripts/00-common.sh <hostname> [--docker]`
3. vm-data-4: `sudo scripts/20-data.sh` → restore DB → rsync ไฟล์ Data API
4. vm-service-1: `sudo scripts/30-swarm.sh init` · vm-service-2: `sudo scripts/30-swarm.sh join <token>`
5. vm-service-1: `stacks/erp/deploy-stack.sh`
6. gw-1 / gw-5: copy wildcard cert → `sudo scripts/10-gateway.sh gw-1` / `gw-5`
7. vm-jenkins: `sudo scripts/40-jenkins.sh`
8. ทดสอบ failover ตาม runbook แล้วค่อย cutover

## Compose และวิธีสั่งงาน

compose ทุกไฟล์อยู่ใน repo นี้ที่เดียว (clone ไว้ที่ `/opt/erp-infra` บนทุกเครื่อง) ห้าม copy ไปแก้ที่อื่น
แต่ละกลุ่มใช้คำสั่งต่างกันตามชนิดของเครื่อง:

| ไฟล์ | เครื่อง | คำสั่ง | เหตุผล |
|---|---|---|---|
| `stacks/erp/stack.yml` | vm-service-1 (manager) | `stacks/erp/deploy-stack.sh` (= `docker stack deploy`) | กระจาย 2 เครื่อง, rolling update, ย้าย ticker ตอนเครื่องล่ม |
| `data/compose.yml` | vm-data-4 | `data/dc.sh up -d` (= `docker compose`) | เครื่องเดียว ไม่ต้องใช้ Swarm |
| `jenkins/compose.yml` | vm-jenkins | `jenkins/dc.sh up -d --build` | เครื่องเดียว |
| — (nginx + keepalived บนตัวเครื่อง) | gw-1, gw-5 | `scripts/10-gateway.sh` / `11-sync-gw.sh` | keepalived ต้องจัดการ IP ของเครื่องโดยตรง ไม่ใส่ใน container |

ห้ามรัน `docker compose up` กับ `stacks/erp/stack.yml` บน vm-service: จะได้ container ธรรมดาที่ไม่อยู่ใน Swarm
ไม่มี rolling update และไม่ย้ายเครื่องตอนล่ม

### เปลี่ยนแปลง service ยังไง

1. แก้ไฟล์ใน repo บนเครื่องตัวเอง → commit → push
2. บนเครื่องที่เกี่ยวข้อง: `cd /opt/erp-infra && sudo git pull`
3. apply ด้วยคำสั่งในตารางข้างบน (เช่น `data/dc.sh up -d` จะสร้างใหม่เฉพาะ service ที่ไฟล์เปลี่ยน)

ค่าที่เป็นความลับไม่อยู่ใน repo: `/opt/data/.env`, `stacks/erp/*.env`, `secrets.env` และ cert ใน `/etc/nginx/ssl`

## กฎของ repo

- แก้ config ผ่าน Git เท่านั้น แล้วใช้ script apply ห้ามแก้ไฟล์บนเครื่องตรง ๆ
- ห้าม commit รหัสผ่านหรือ cert (`.gitignore` กันไว้แล้ว) ไฟล์ `*.env` จริงวางบนเครื่องด้วยสิทธิ์ `600`
- image ทุกตัว pin tag ห้ามใช้ `latest` (tag ที่ deploy อยู่บันทึกใน `stacks/erp/versions.env`)
