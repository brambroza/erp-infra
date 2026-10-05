# erp-infra

Infrastructure as code ของระบบ ERP (nisolution.co.th) แบบ High Availability

<p align="center">
  <img src="docs/infra-diagram.svg" alt="ERP infra: ผู้ใช้ → Cloudflare → Router → VIP 192.168.88.100 (erp-gw-01 MASTER / erp-gw-02 BACKUP) → Swarm erp-app-01 / erp-app-02 → erp-db-01; GitHub Actions → Docker Hub; Jenkins erp-ci-01 deploy ผ่าน ssh เข้า erp-app-01" width="100%">
</p>

**Flow แบบย่อ**

| สถานการณ์ | เส้นทาง | ผล |
|---|---|---|
| ปกติ | ผู้ใช้ → Cloudflare → Router → VIP (erp-gw-01) → erp-app-01 หรือ erp-app-02 → erp-db-01 | โหลดแบ่งครึ่ง hub / socket ของผู้ใช้คนเดิมไปเครื่องเดิม |
| erp-gw-01 ล่ม | ผู้ใช้ → Router → VIP (erp-gw-02) → erp-app-01 / 02 | สะดุดราว 2–3 วินาที ไม่ต้องแก้ Router หรือ DNS |
| erp-app-01 หรือ 02 ล่ม | gateway → เครื่องที่เหลือ → erp-db-01 | ใช้งานต่อได้ ถ้า erp-app-01 (manager) ล่ม deploy ไม่ได้จนกว่าจะกลับมา |
| Deploy | push main → GitHub Actions → Docker Hub → Jenkins (erp-ci-01) → ssh erp-app-01 → อัปเดตทีละเครื่อง | ไม่ต้องปิดระบบ health ไม่ผ่านจะ rollback เอง |

รายละเอียด diagram, flow และ resource อยู่ใน [docs/architecture.md](docs/architecture.md)
แผนย้ายจากเครื่องเดิมทีละ phase อยู่ใน [docs/migration-plan.md](docs/migration-plan.md)
คำสั่งติดตั้งและทดสอบอยู่ใน [docs/runbook.md](docs/runbook.md)

## เครื่องทั้งหมด

| VM | IP | หน้าที่ | ที่รันอยู่ |
|---|---|---|---|
| — (VIP) | 192.168.88.100 | IP กลางที่ Router port forward เข้า | ย้ายระหว่าง gateway ด้วย keepalived |
| erp-gw-01 | 192.168.88.101 | Gateway MASTER (priority 110) | nginx, keepalived (บนตัวเครื่อง) |
| erp-gw-02 | 192.168.88.102 | Gateway BACKUP (priority 100) | nginx, keepalived (บนตัวเครื่อง) |
| erp-app-01 | 192.168.88.111 | Swarm manager | erpapp, erpapi, chat-api, ticker (stack `erp`) |
| erp-app-02 | 192.168.88.112 | Swarm worker | erpapp, erpapi, chat-api |
| erp-db-01 | 192.168.88.12 | Data | SQL Server 2022 Express, Redis 7.4, RabbitMQ 4.0, NFS (compose `data`) |
| erp-ci-01 | 192.168.88.131 | CI/CD | Jenkins :8110 (compose `jenkins`) |
| เครื่องเดิม | 192.168.88.11 | production เดิม (ก่อน cutover) | app :3030, n8n :5678, :10053 ยังอยู่ที่นี่ต่อ |
| Zabbix | 192.168.88.21 | monitoring | zabbix web / api / monitor |

ค่าทั้งหมดอยู่ใน `inventory.env`

## โครงสร้าง repo

```
erp-infra/
├── inventory.env              # hostname / IP ทั้งหมด (แก้ที่นี่ที่เดียว)
├── secrets.env.example        # VRRP_PASS → copy เป็น secrets.env
├── scripts/
│   ├── 00-audit-legacy.sh     # เครื่องเดิม: เก็บข้อมูลก่อนย้าย (อ่านอย่างเดียว)
│   ├── 00-common.sh           # ทุกเครื่อง: hostname, hosts, sysctl, ufw, zabbix-agent, docker
│   ├── 10-gateway.sh          # erp-gw-01 / erp-gw-02: nginx + keepalived
│   ├── 11-sync-gw.sh          # รันบน erp-gw-01: sync config (+cert) ไป erp-gw-02
│   ├── 20-data.sh             # erp-db-01: compose + NFS + backup cron
│   ├── 30-swarm.sh            # erp-app-01 init / erp-app-02 join
│   ├── 40-jenkins.sh          # erp-ci-01: Jenkins + docker cli
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
└── docs/                      # architecture.md, migration-plan.md, runbook.md, router/, infra-diagram.svg
```

## ลำดับติดตั้งแบบย่อ

0. เครื่องเดิม: `sudo SA_PASS=... scripts/00-audit-legacy.sh` เก็บข้อมูลก่อน (อ่านอย่างเดียว)
1. แก้ `inventory.env`, `versions.env` และ path volume ตามผล audit แล้ว clone repo ไว้ที่ `/opt/erp-infra` บนทุกเครื่องใหม่
2. ทุกเครื่อง: `sudo scripts/00-common.sh <hostname> [--docker]`
3. erp-db-01: `sudo scripts/20-data.sh` → restore DB → rsync ไฟล์ Data API
4. erp-app-01: `sudo scripts/30-swarm.sh init` · erp-app-02: `sudo scripts/30-swarm.sh join <token>`
5. erp-app-01: `stacks/erp/deploy-stack.sh`
6. erp-gw-01 / erp-gw-02: copy wildcard cert → `sudo scripts/10-gateway.sh erp-gw-01` / `erp-gw-02`
7. erp-ci-01: `sudo scripts/40-jenkins.sh`
8. ทดสอบ failover ตาม runbook แล้วค่อย cutover

## Compose และวิธีสั่งงาน

compose ทุกไฟล์อยู่ใน repo นี้ที่เดียว (clone ไว้ที่ `/opt/erp-infra` บนทุกเครื่อง) ห้าม copy ไปแก้ที่อื่น
แต่ละกลุ่มใช้คำสั่งต่างกันตามชนิดของเครื่อง:

| ไฟล์ | เครื่อง | คำสั่ง | เหตุผล |
|---|---|---|---|
| `stacks/erp/stack.yml` | erp-app-01 (manager) | `stacks/erp/deploy-stack.sh` (= `docker stack deploy`) | กระจาย 2 เครื่อง, rolling update, ย้าย ticker ตอนเครื่องล่ม |
| `data/compose.yml` | erp-db-01 | `data/dc.sh up -d` (= `docker compose`) | เครื่องเดียว ไม่ต้องใช้ Swarm |
| `jenkins/compose.yml` | erp-ci-01 | `jenkins/dc.sh up -d --build` | เครื่องเดียว |
| — (nginx + keepalived บนตัวเครื่อง) | erp-gw-01, erp-gw-02 | `scripts/10-gateway.sh` / `11-sync-gw.sh` | keepalived ต้องจัดการ IP ของเครื่องโดยตรง ไม่ใส่ใน container |

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
