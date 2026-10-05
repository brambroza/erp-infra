#!/usr/bin/env python3
"""สร้าง / อัปเดต Map "ERP HA" และ Dashboard "ERP HA" ใน Zabbix ผ่าน API (รันซ้ำได้)

ใช้:
  export ZBX_URL=http://192.168.88.21/zabbix      # URL หน้าเว็บ Zabbix (ที่มี /api_jsonrpc.php)
  export ZBX_TOKEN=xxxxxxxx                        # User settings → API tokens (สิทธิ์ Super admin)
  python3 monitoring/zabbix/make-map.py

Map: พื้นหลัง = map/erp-ha-topology.png (สร้างจาก map/gen_topology.py)
     จุดที่มุมขวาบนของการ์ดแต่ละเครื่อง: เขียว = ปกติ · แดง = มี problem · เทา = ปิด / maintenance
ต้องเพิ่ม host ใน Zabbix ครบก่อน (host ที่ยังไม่มีจะถูกข้ามพร้อมแจ้งเตือน)
"""
import base64, json, os, ssl, sys, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
URL = os.environ.get("ZBX_URL", "").rstrip("/")
TOKEN = os.environ.get("ZBX_TOKEN", "")
NAME = "ERP HA"
GROUP = "ERP-HA"
W, H = 1240, 680

# ตำแหน่งจุดสถานะ (มุมซ้ายบนของไอคอน 28px) — ตรงกับ layout ใน docs/infra-diagram.svg
DOTS = [                    # = จุดกลางวงใน map/gen_topology.py ลบ 14
    ("erp-vip",    426, 316),
    ("erp-gw-01",  576, 156),
    ("erp-gw-02",  576, 476),
    ("erp-app-01", 798, 156),
    ("erp-app-02", 798, 476),
    ("erp-db-01",  1074, 286),
    ("erp-ci-01",  1074, 90),
]

if not URL or not TOKEN:
    sys.exit("ตั้ง ZBX_URL และ ZBX_TOKEN ก่อน (ดูหัวไฟล์)")

CTX = ssl.create_default_context()
if os.environ.get("ZBX_INSECURE") == "1":          # Zabbix ใช้ cert self-signed
    CTX.check_hostname = False
    CTX.verify_mode = ssl.CERT_NONE

_id = 0
VERSION = None


def api(method, params, auth=True):
    global _id
    _id += 1
    body = {"jsonrpc": "2.0", "method": method, "params": params, "id": _id}
    headers = {"Content-Type": "application/json-rpc"}
    if auth:
        if VERSION and VERSION >= (6, 4):
            headers["Authorization"] = f"Bearer {TOKEN}"
        else:
            body["auth"] = TOKEN
    req = urllib.request.Request(f"{URL}/api_jsonrpc.php", json.dumps(body).encode(), headers)
    with urllib.request.urlopen(req, context=CTX, timeout=30) as r:
        res = json.load(r)
    if "error" in res:
        raise RuntimeError(f"{method}: {res['error'].get('message')} {res['error'].get('data')}")
    return res["result"]


def b64(path):
    with open(path, "rb") as f:
        return base64.b64encode(f.read()).decode()


def upsert_image(name, path, imagetype):
    found = api("image.get", {"filter": {"name": name}, "output": ["imageid"]})
    data = b64(path)
    if found:
        api("image.update", {"imageid": found[0]["imageid"], "image": data})
        return found[0]["imageid"]
    return api("image.create", {"name": name, "imagetype": imagetype, "image": data})["imageids"][0]


def main():
    global VERSION
    v = api("apiinfo.version", {}, auth=False)
    VERSION = tuple(int(x) for x in v.split(".")[:2])
    print(f"Zabbix API {v}")

    bg = upsert_image("erp-ha-background", os.path.join(HERE, "map/erp-ha-topology.png"), 2)
    ok = upsert_image("erp-dot-ok", os.path.join(HERE, "map/erp-dot-ok.png"), 1)
    bad = upsert_image("erp-dot-problem", os.path.join(HERE, "map/erp-dot-problem.png"), 1)
    off = upsert_image("erp-dot-off", os.path.join(HERE, "map/erp-dot-off.png"), 1)

    hosts = {h["host"]: h["hostid"] for h in api("host.get", {
        "filter": {"host": [d[0] for d in DOTS]}, "output": ["hostid", "host"]})}
    selements = []
    for i, (host, x, y) in enumerate(DOTS, 1):
        if host not in hosts:
            print(f"  ข้าม {host}: ยังไม่มี host นี้ใน Zabbix")
            continue
        selements.append({
            "selementid": str(i), "elementtype": 0, "elements": [{"hostid": hosts[host]}],
            "iconid_off": ok, "iconid_on": bad, "iconid_disabled": off, "iconid_maintenance": off,
            "use_iconmap": 0, "x": x, "y": y, "label": "{HOST.NAME}",
        })

    mapdef = {
        "name": NAME, "width": W, "height": H, "backgroundid": bg,
        "label_type": 4,            # ไม่แสดงข้อความใต้จุด (ข้อมูลอยู่ในรูปพื้นหลังแล้ว)
        "highlight": 1, "markelements": 1, "expandproblem": 1, "show_unack": 0,
        "selements": selements, "links": [],
    }
    found = api("map.get", {"filter": {"name": NAME}, "output": ["sysmapid"]})
    if found:
        mapid = found[0]["sysmapid"]
        api("map.update", {"sysmapid": mapid, **mapdef})
        print(f"อัปเดต map '{NAME}' ({len(selements)} จุด)")
    else:
        mapid = api("map.create", mapdef)["sysmapids"][0]
        print(f"สร้าง map '{NAME}' ({len(selements)} จุด)")

    make_dashboard(mapid)


def make_dashboard(mapid):
    groups = api("hostgroup.get", {"filter": {"name": [GROUP]}, "output": ["groupid"]})
    if not groups:
        print(f"ไม่พบ host group {GROUP} — ข้ามการสร้าง dashboard (เพิ่ม map ใน dashboard เองได้)")
        return
    gid = groups[0]["groupid"]
    cols = 72 if VERSION >= (7, 0) else 24        # 7.0 ขยาย grid เป็น 72 ช่อง
    half = cols // 2
    rowh = 2 if VERSION >= (7, 0) else 1          # 7.0 ใช้แถวเตี้ยลง

    def widgets(suffix):
        g = {"type": 2, "name": "groupids" + suffix, "value": gid}
        return [
            {"type": "map", "name": "Infrastructure", "x": 0, "y": 0, "width": cols, "height": 10 * rowh,
             "fields": [{"type": 8, "name": "sysmapid" + suffix, "value": mapid}]},
            {"type": "problems", "name": "ปัญหาที่ยังไม่จบ (ERP-HA)", "x": 0, "y": 10 * rowh, "width": half, "height": 6 * rowh,
             "fields": [g]},
            {"type": "web", "name": "เข้าเว็บผ่าน VIP", "x": half, "y": 10 * rowh, "width": half, "height": 3 * rowh,
             "fields": [g]},
            {"type": "hostavail", "name": "Agent ของแต่ละเครื่อง", "x": half, "y": 13 * rowh, "width": half, "height": 3 * rowh,
             "fields": [g]},
        ]

    found = api("dashboard.get", {"filter": {"name": NAME}, "output": ["dashboardid"]})
    last = None
    for suffix in ("", ".0"):                    # ชื่อ field ต่างกันตามเวอร์ชัน → ลองทั้งสองแบบ
        body = {"name": NAME, "display_period": 30, "auto_start": 1, "pages": [{"widgets": widgets(suffix)}]}
        try:
            if found:
                api("dashboard.update", {"dashboardid": found[0]["dashboardid"], **body})
                print(f"อัปเดต dashboard '{NAME}'")
            else:
                api("dashboard.create", body)
                print(f"สร้าง dashboard '{NAME}'")
            return
        except RuntimeError as e:
            last = e
    print(f"สร้าง dashboard ไม่สำเร็จ ({last}) — map สร้างแล้ว: Dashboards → Create → เพิ่ม widget Map เลือก '{NAME}'")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001
        sys.exit(f"ผิดพลาด: {e}")
