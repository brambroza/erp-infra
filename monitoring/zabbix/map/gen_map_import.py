#!/usr/bin/env python3
"""สร้างไฟล์ import ของ Zabbix map "ERP HA Topology" (วาดด้วย shape/element/link ของ Zabbix เอง ไม่ใช้รูปพื้นหลัง)

ผลลัพธ์ (โฟลเดอร์เดียวกัน):
  zbx-map-erp-ha-topology.yaml        มีไอคอน + shape + element + link + link indicator (เส้นแดงเมื่อ trigger เกิด)
  zbx-map-erp-ha-topology-basic.yaml  แบบเดียวกันแต่ไม่มี link indicator (ใช้ถ้าแบบเต็ม import ไม่ผ่าน)
  zbx-map-erp-ha-topology-preview.svg ภาพจำลองไว้ตรวจ layout

ต้องมี host ใน Zabbix ครบก่อน import: erp-vip, erp-gw-01, erp-gw-02, erp-app-01, erp-app-02, erp-db-01, erp-ci-01
"""
import base64, os, yaml

HERE = os.path.dirname(os.path.abspath(__file__))
ZBX = os.path.dirname(HERE)
W, H = 1240, 680
BG, BAND, INK, MUTED = '0D1621', '111D2A', 'E6EDF5', '8796A8'
EDGE, APP, DATA, CI, OLD = '7AA2FF', '3DD6AE', 'F2B455', 'B69CFF', '7E8A98'
RED = 'D92D20'
FONT = '8'   # Tahoma (มีอักษรไทยทั้ง Windows / macOS)

# จุดกลางของแต่ละโหนด (ตรงกับภาพ topology)
N = {
    'users': (78, 330), 'cf': (190, 330), 'router': (302, 330), 'vip': (440, 330),
    'gw1': (590, 200), 'gw2': (590, 500), 'app1': (812, 200), 'app2': (812, 500),
    'db': (1088, 300), 'ci': (1088, 104), 'old': (1088, 588),
}
HOSTS = {'vip': 'erp-vip', 'gw1': 'erp-gw-01', 'gw2': 'erp-gw-02', 'app1': 'erp-app-01',
         'app2': 'erp-app-02', 'db': 'erp-db-01', 'ci': 'erp-ci-01'}
TIER = {'vip': EDGE, 'gw1': EDGE, 'gw2': EDGE, 'app1': APP, 'app2': APP, 'db': DATA, 'ci': CI}
STATIC = {'users': 'erp-node-users', 'cf': 'erp-node-cloud', 'router': 'erp-node-router', 'old': 'erp-node-server'}

shapes = []


def shape(kind, x, y, w, h, text='', size=11, color=INK, halign='0', valign='1', bg='', border='0', bw='0', bc='000000'):
    shapes.append({
        'type': '1' if kind == 'ellipse' else '0', 'x': str(int(x)), 'y': str(int(y)), 'width': str(int(w)), 'height': str(int(h)),
        'text': text, 'font': FONT, 'font_size': str(size), 'font_color': color,
        'text_halign': halign, 'text_valign': valign,          # halign 0=กลาง 1=ซ้าย 2=ขวา · valign 0=กลาง 1=บน 2=ล่าง
        'border_type': border, 'border_width': bw, 'border_color': bc,   # border 0=ไม่มี 1=เส้น 2=จุด 3=ประ
        'background_color': bg, 'zindex': str(len(shapes)),
    })


# ---------- พื้นและแถบชั้น ----------
shape('rect', 0, 0, W, H, bg=BG)
for x, w, name, col in [(16, 352, '  อินเทอร์เน็ต', MUTED), (380, 290, '  Gateway — HA คู่', EDGE),
                        (682, 262, '  Docker Swarm — stack erp', APP), (956, 268, '  Data และ CI', DATA)]:
    shape('rect', x, 16, w, H - 32, '\n' + name, 12, col, '1', '1', bg=BAND)
shape('rect', 514, 120, 152, 494, 'VRRP pair · VIP ย้ายเองใน ~2 วิ', 10, MUTED, '0', '2', border='3', bw='1', bc='33466B')

# ---------- วงกลม ----------
for k, (cx, cy) in N.items():
    if k in HOSTS:
        shape('ellipse', cx - 26, cy - 26, 52, 52, bg=BG, border='1', bw='3', bc=TIER[k])
    else:
        shape('ellipse', cx - 22, cy - 22, 44, 44, bg=BAND, border='3' if k == 'old' else '1', bw='2', bc=OLD)

# ---------- ป้ายข้อความ ----------
def label(x, y, w, h, lines, color=INK, halign='0', size=11):
    shape('rect', x, y, w, h, '\n'.join(lines), size, color, halign, '1')

label(18, 358, 120, 44, ['ผู้ใช้', 'HTTPS 443'])
label(130, 358, 120, 44, ['Cloudflare', 'proxied'])
label(242, 358, 120, 44, ['Router', 'NAT 80/443 → VIP'])
label(318, 362, 136, 44, ['VIP', '192.168.88.100'], halign='2')
label(510, 126, 160, 46, ['erp-gw-01', '192.168.88.101', 'MASTER · nginx'])
label(510, 532, 160, 56, ['erp-gw-02', '192.168.88.102', 'BACKUP · nginx'])
for key, name, ip, role in [('app1', 'erp-app-01', '192.168.88.111', 'manager'), ('app2', 'erp-app-02', '192.168.88.112', 'worker')]:
    cx, cy = N[key]
    y = cy - 128 if key == 'app1' else cy + 32           # app-01 ป้ายอยู่บน, app-02 อยู่ล่าง → เส้นทแยงตรงกลางไม่ทับข้อความ
    label(cx - 85, y, 170, 96, [f'{name} ({role})', ip, 'erpapp 8284', 'erpapi 6334 · 6344', 'chat-api 6335'])
label(1003, 332, 170, 110, ['erp-db-01', '192.168.88.12', 'SQL Server Express 1433', 'Redis 6379', 'RabbitMQ 5672', 'NFS erp-files 2049'])
label(1120, 84, 112, 50, ['erp-ci-01', '192.168.88.131', 'Jenkins 8110'], halign='1')
label(1116, 568, 116, 64, ['เครื่องเดิม', '192.168.88.11', 'app 3030 · n8n 5678'], halign='1')
label(600, 334, 70, 34, ['VRRP', 'ทุก 1 วิ'], MUTED, '1', 10)
label(28, 560, 300, 70, ['● เขียว = ปกติ   ● แดง = มีปัญหา   ● เทา = ปิด / ซ่อม',
                         'เส้นหนา = เส้นทางหลัก · เส้นประ = สำรอง',
                         'เส้นเป็นสีแดง = ปัญหาบนเส้นทางนั้น'], MUTED, '1', 10)

# ---------- elements ----------
selements, sid = [], {}
for i, (k, (cx, cy)) in enumerate(N.items(), 1):
    sid[k] = str(i)
    base = {'label_location': '-1', 'x': '', 'y': '', 'elementsubtype': '0', 'areatype': '0', 'width': '200', 'height': '200',
            'viewtype': '0', 'use_iconmap': '0', 'selementid': str(i), 'urls': [], 'evaltype': '0'}
    if k in HOSTS:
        base.update({'elementtype': '0', 'elements': [{'host': HOSTS[k]}], 'label': '{HOST.NAME}',
                     'x': str(cx - 14), 'y': str(cy - 14),
                     'icon_off': {'name': 'erp-dot-ok'}, 'icon_on': {'name': 'erp-dot-problem'},
                     'icon_disabled': {'name': 'erp-dot-off'}, 'icon_maintenance': {'name': 'erp-dot-off'}})
    else:
        base.update({'elementtype': '4', 'elements': [], 'label': '', 'x': str(cx - 14), 'y': str(cy - 14),
                     'icon_off': {'name': STATIC[k]}, 'icon_on': {}, 'icon_disabled': {}, 'icon_maintenance': {}})
    selements.append({kk: base[kk] for kk in ['elementtype', 'elements', 'label', 'label_location', 'x', 'y', 'elementsubtype',
                                             'areatype', 'width', 'height', 'viewtype', 'use_iconmap', 'selementid',
                                             'icon_off', 'icon_on', 'icon_disabled', 'icon_maintenance', 'urls', 'evaltype']})

# ---------- trigger สำหรับ link indicator (อ่านชื่อ/expression จาก template จริง แล้วแทนชื่อ template ด้วยชื่อ host) ----------
def trig(template_file, template, host, key_contains):
    d = yaml.safe_load(open(os.path.join(ZBX, template_file)))['zabbix_export']
    cands = []
    for t in d['templates']:
        for it in t.get('items', []):
            cands += it.get('triggers', [])
    cands += d.get('triggers', [])
    for tr in cands:
        if key_contains in tr['expression']:
            return {'description': tr['name'], 'expression': tr['expression'].replace(f'/{template}/', f'/{host}/'),
                    'recovery_expression': ''}
    raise SystemExit(f'ไม่พบ trigger {key_contains} ใน {template_file}')

T_WEB = trig('template-erp-web.yaml', 'ERP Web', 'erp-vip', 'web.test.fail[erp via VIP]')
T_SQL = trig('template-erp-data.yaml', 'ERP Data', 'erp-db-01', 'erp.db[c_mssql])=0')
T_DBON = trig('template-erp-data.yaml', 'ERP Data', 'erp-db-01', 'erp.db[mssql_online])=0')
T_KA1 = trig('template-erp-gateway.yaml', 'ERP Gateway', 'erp-gw-01', 'proc.num[keepalived]')
T_KA2 = trig('template-erp-gateway.yaml', 'ERP Gateway', 'erp-gw-02', 'proc.num[keepalived]')

# drawtype 0=เส้น 2=หนา 3=จุด 4=ประ
LINKS = [
    ('users', 'cf', '0', OLD, []), ('cf', 'router', '0', OLD, []),
    ('router', 'vip', '2', EDGE, [T_WEB]),
    ('vip', 'gw1', '2', EDGE, []), ('vip', 'gw2', '4', EDGE, []),
    ('gw1', 'gw2', '3', EDGE, [T_KA1, T_KA2]),
    ('gw1', 'app1', '2', APP, []), ('gw1', 'app2', '0', APP, []),
    ('gw2', 'app1', '4', APP, []), ('gw2', 'app2', '4', APP, []),
    ('app1', 'db', '2', DATA, [T_SQL, T_DBON]), ('app2', 'db', '2', DATA, [T_SQL, T_DBON]),
    ('ci', 'app1', '4', CI, []),
]


def links(with_triggers):
    out = []
    for a, b, dt, col, trs in LINKS:
        out.append({'drawtype': dt, 'color': col, 'label': '', 'selementid1': sid[a], 'selementid2': sid[b],
                    'linktriggers': [{'drawtype': '2', 'color': RED, 'trigger': t} for t in trs] if with_triggers else []})
    return out


def images():
    out = []
    for name in ['erp-dot-ok', 'erp-dot-problem', 'erp-dot-off', *STATIC.values()]:
        with open(os.path.join(HERE, f'{name}.png'), 'rb') as f:
            out.append({'name': name, 'imagetype': '1', 'encodedImage': base64.b64encode(f.read()).decode()})
    return out


def export(with_triggers):
    m = {
        'name': 'ERP HA Topology', 'width': str(W), 'height': str(H),
        'label_type': '4', 'label_location': '0', 'highlight': '1', 'expandproblem': '1', 'markelements': '1',
        'show_unack': '0', 'severity_min': '0', 'show_suppressed': '0',
        'grid_size': '50', 'grid_show': '0', 'grid_align': '0',
        'label_format': '0', 'label_type_host': '2', 'label_type_hostgroup': '2', 'label_type_trigger': '2',
        'label_type_map': '2', 'label_type_image': '2', 'label_string_host': '', 'label_string_hostgroup': '',
        'label_string_trigger': '', 'label_string_map': '', 'label_string_image': '', 'expand_macros': '1',
        'background': {}, 'iconmap': {}, 'urls': [],
        'selements': selements, 'shapes': shapes, 'lines': [], 'links': links(with_triggers),
    }
    return {'zabbix_export': {'version': '6.0', 'images': images(), 'maps': [m]}}


hdr = ('# Zabbix map "ERP HA Topology" — Monitoring → Maps → Import (ติ๊ก Images: Create new, Maps: Create new)\n'
       '# ต้องมี host ครบ: erp-vip, erp-gw-01, erp-gw-02, erp-app-01, erp-app-02, erp-db-01, erp-ci-01\n'
       '# สร้างจาก monitoring/zabbix/map/gen_map_import.py — แก้ที่ script แล้วสร้างใหม่\n')
for fn, tr in [('zbx-map-erp-ha-topology.yaml', True), ('zbx-map-erp-ha-topology-basic.yaml', False)]:
    with open(os.path.join(HERE, fn), 'w') as f:
        f.write(hdr + yaml.safe_dump(export(tr), allow_unicode=True, sort_keys=False, width=1000))

# ---------- ภาพจำลอง (ประมาณการแสดงผลของ Zabbix) ----------
def esc(s): return s.replace('&', '&amp;').replace('<', '&lt;')
sv = [f'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="{W}" height="{H}">']
for s in shapes:
    x, y, w, h = (int(s[k]) for k in ('x', 'y', 'width', 'height'))
    fill = f'#{s["background_color"]}' if s['background_color'] else 'none'
    stroke = 'none' if s['border_type'] == '0' else f'#{s["border_color"]}'
    dash = {'2': '2 3', '3': '5 4'}.get(s['border_type'], '')
    if s['type'] == '1':
        sv.append(f'<ellipse cx="{x+w/2}" cy="{y+h/2}" rx="{w/2}" ry="{h/2}" fill="{fill}" stroke="{stroke}" stroke-width="{s["border_width"]}" stroke-dasharray="{dash}"/>')
    else:
        sv.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" fill="{fill}" stroke="{stroke}" stroke-width="{s["border_width"]}" stroke-dasharray="{dash}"/>')
    if s['text']:
        lines = s['text'].split('\n'); fs = int(s['font_size']); lh = fs * 1.35
        anchor, tx = {'0': ('middle', x + w / 2), '1': ('start', x + 2), '2': ('end', x + w - 2)}[s['text_halign']]
        y0 = {'1': y + fs, '2': y + h - lh * (len(lines) - 1) - 4, '0': y + h / 2 - lh * (len(lines) - 1) / 2 + fs / 3}[s['text_valign']]
        for i, ln in enumerate(lines):
            sv.append(f'<text x="{tx}" y="{y0 + i*lh:.0f}" font-family="Tahoma, Noto Sans Thai, sans-serif" font-size="{fs}" fill="#{s["font_color"]}" text-anchor="{anchor}">{esc(ln)}</text>')
for a, b, dt, col, _ in LINKS:
    (x1, y1), (x2, y2) = N[a], N[b]
    sw = {'2': 3, '0': 1.5, '3': 2, '4': 1.5}[dt]; da = {'3': '1 5', '4': '6 5'}.get(dt, '')
    sv.append(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="#{col}" stroke-width="{sw}" stroke-dasharray="{da}" stroke-linecap="round"/>')
for e in selements:
    icon = e['icon_off']['name']
    with open(os.path.join(HERE, f'{icon}.png'), 'rb') as f:
        data = base64.b64encode(f.read()).decode()
    sv.append(f'<image x="{e["x"]}" y="{e["y"]}" width="28" height="28" xlink:href="data:image/png;base64,{data}"/>')
sv.append('</svg>')
open(os.path.join(HERE, 'zbx-map-erp-ha-topology-preview.svg'), 'w').write('\n'.join(sv))
print('ok')
