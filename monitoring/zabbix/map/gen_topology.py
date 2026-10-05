#!/usr/bin/env python3
"""พื้นหลัง Map ของ Zabbix แบบ topology (จอ NOC สีเข้ม)

แต่ละเครื่องเป็นวงกลมที่มี "ช่อง" ตรงกลาง — Zabbix วางจุดสถานะ (เขียว/แดง/เทา) ลงในช่องนั้นพอดี
ตำแหน่งช่องอยู่ใน NODES ด้านล่าง และต้องตรงกับ DOTS ใน ../make-map.py (มุมซ้ายบน = จุดกลาง - 14)

ใช้: python3 gen_topology.py > erp-ha-topology.svg   แล้ว render เป็น PNG 1240×680
"""
from html import escape

W, H = 1240, 680
C = {
    'bg': '#0D1621', 'grid': '#1A2633', 'band': '#111D2A', 'ink': '#E6EDF5', 'muted': '#8796A8', 'dim': '#5D6B7C',
    'edge': '#7AA2FF', 'app': '#3DD6AE', 'data': '#F2B455', 'ci': '#B69CFF', 'old': '#7E8A98',
}
o = []
a = o.append


def t(x, y, s, size=12, fill=None, weight=400, anchor='start', mono=False, ls=0):
    fam = 'JetBrains Mono, ui-monospace, Menlo, Consolas, Noto Sans Thai, monospace' if mono else \
          'IBM Plex Sans Thai, Noto Sans Thai, Sukhumvit Set, Tahoma, sans-serif'
    a(f'<text x="{x}" y="{y}" font-family="{fam}" font-size="{size}" font-weight="{weight}" fill="{fill or C["ink"]}" '
      f'text-anchor="{anchor}" letter-spacing="{ls}">{escape(s)}</text>')


def socket(x, y, tier, r=24):
    """วงกลมของเครื่องที่ Zabbix เฝ้า: วงนอกสีตามชั้น + ช่องเข้มตรงกลางรอจุดสถานะ"""
    col = C[tier]
    a(f'<circle cx="{x}" cy="{y}" r="{r+10}" fill="{col}" opacity="0.10"/>')
    a(f'<circle cx="{x}" cy="{y}" r="{r}" fill="{C["bg"]}" stroke="{col}" stroke-width="2.5"/>')
    a(f'<circle cx="{x}" cy="{y}" r="15" fill="#0A1119" stroke="{col}" stroke-opacity="0.35" stroke-width="1"/>')


def glyph_node(x, y, kind, tier='old', r=20):
    """โหนดที่ไม่ได้เฝ้าใน Zabbix (ผู้ใช้, Cloudflare, Router, เครื่องเดิม) — วาดไอคอนในวง"""
    col = C[tier]
    dash = ' stroke-dasharray="4 3"' if kind == 'legacy' else ''
    a(f'<circle cx="{x}" cy="{y}" r="{r}" fill="{C["band"]}" stroke="{col}" stroke-width="1.6"{dash}/>')
    s = f'stroke="{C["ink"]}" stroke-width="1.6" fill="none" stroke-linecap="round" stroke-linejoin="round"'
    if kind == 'users':
        a(f'<circle cx="{x-4}" cy="{y-4}" r="4" {s}/><path d="M{x-12} {y+9}c1-6 4-8 8-8s7 2 8 8" {s}/>')
        a(f'<circle cx="{x+6}" cy="{y-6}" r="3" {s} opacity=".7"/><path d="M{x+4} {y}c4 0 7 2 8 7" {s} opacity=".7"/>')
    elif kind == 'cloud':
        a(f'<path d="M{x-10} {y+6}h19a6 6 0 0 0 0-12a8 8 0 0 0-15-2a5.5 5.5 0 0 0-4 14z" {s}/>')
    elif kind == 'router':
        a(f'<path d="M{x-10} {y}h20M{x} {y-10}v20M{x+6} {y-4}l4 4l-4 4M{x-6} {y-4}l-4 4l4 4M{x-4} {y-6}l4-4l4 4M{x-4} {y+6}l4 4l4-4" {s}/>')
    elif kind == 'legacy':
        a(f'<rect x="{x-9}" y="{y-9}" width="18" height="7" rx="1.5" {s}/><rect x="{x-9}" y="{y+2}" width="18" height="7" rx="1.5" {s}/>')


def link(d, tier='muted', kind='solid', width=2.2, label=None, lx=0, ly=0, anchor='middle'):
    col = C[tier] if tier in C else C['muted']
    dash = {'solid': '', 'standby': ' stroke-dasharray="7 6"', 'beat': ' stroke-dasharray="1 6" stroke-linecap="round"',
            'deploy': ' stroke-dasharray="10 5"'}[kind]
    op = '0.95' if kind == 'solid' else '0.8'
    a(f'<path d="{d}" fill="none" stroke="{col}" stroke-width="{width}" stroke-opacity="{op}"{dash}/>')
    if label:
        t(lx, ly, label, 10.5, C['muted'], anchor=anchor)


def chip(x, y, text, tier):
    w = 12 + len(text) * 6.4
    a(f'<rect x="{x}" y="{y-12}" width="{w:.0f}" height="17" rx="8.5" fill="{C[tier]}" fill-opacity="0.12" stroke="{C[tier]}" stroke-opacity="0.55"/>')
    t(x + w / 2, y + 1, text, 10.5, C[tier], 600, 'middle', mono=True)
    return x + w + 5


def label(x, y, name, ip, sub, tier, anchor='middle'):
    t(x, y, name, 15, C['ink'], 700, anchor)
    t(x, y + 17, ip, 11.5, C[tier], 500, anchor, mono=True)
    if sub:
        t(x, y + 33, sub, 11, C['muted'], 400, anchor)


# ------------------------------------------------------------------ canvas
a(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">')
a('<defs><pattern id="g" width="24" height="24" patternUnits="userSpaceOnUse">'
  f'<circle cx="1" cy="1" r="1" fill="{C["grid"]}"/></pattern></defs>')
a(f'<rect width="{W}" height="{H}" fill="{C["bg"]}"/><rect width="{W}" height="{H}" fill="url(#g)"/>')

# แถบชั้น (tier) + ชื่อชั้น
for x, w, name, tier in [(16, 352, 'อินเทอร์เน็ต', 'old'), (380, 290, 'Gateway — HA คู่', 'edge'),
                         (682, 262, 'Docker Swarm — stack erp', 'app'), (956, 268, 'Data และ CI', 'data')]:
    a(f'<rect x="{x}" y="16" width="{w}" height="{H-32}" rx="18" fill="{C["band"]}" fill-opacity="0.55"/>')
    a(f'<rect x="{x+16}" y="34" width="4" height="14" rx="2" fill="{C[tier]}"/>')
    t(x + 28, 46, name, 12.5, C[tier], 700, ls=0.3)

# ------------------------------------------------------------------ nodes (ตำแหน่งกลางวง)
N = {
    'users': (78, 330), 'cf': (190, 330), 'router': (302, 330), 'vip': (440, 330),
    'gw1': (590, 170), 'gw2': (590, 490), 'app1': (812, 170), 'app2': (812, 490),
    'db': (1088, 300), 'ci': (1088, 104), 'old': (1088, 588),
}

# กรอบกลุ่ม (วาดก่อนเส้น)
a(f'<rect x="514" y="112" width="152" height="478" rx="22" fill="none" stroke="{C["edge"]}" stroke-opacity="0.28" stroke-dasharray="3 5"/>')
t(590, 610, 'VRRP pair · VIP ย้ายเองใน ~2 วิ', 10.5, C['muted'], anchor='middle')

# ------------------------------------------------------------------ links
X, Y = 0, 1
u, cf, rt, vip = N['users'], N['cf'], N['router'], N['vip']
link(f'M{u[X]+20} {u[Y]}H{cf[X]-20}', 'old')
link(f'M{cf[X]+20} {cf[Y]}H{rt[X]-20}', 'old')
link(f'M{rt[X]+20} {rt[Y]}H{vip[X]-26}', 'edge', label='443 → VIP', lx=(rt[X]+vip[X])/2 + 2, ly=rt[Y] - 10)
g1, g2 = N['gw1'], N['gw2']
link(f'M{vip[X]+26} {vip[Y]-6}C{vip[X]+70} {vip[Y]-6} {g1[X]-80} {g1[Y]} {g1[X]-26} {g1[Y]}', 'edge', 'solid', label='active', lx=528, ly=232, anchor='end')
link(f'M{vip[X]+26} {vip[Y]+6}C{vip[X]+70} {vip[Y]+6} {g2[X]-80} {g2[Y]} {g2[X]-26} {g2[Y]}', 'edge', 'standby', label='standby', lx=506, ly=466, anchor='end')
link(f'M{g1[X]} {g1[Y]+94}V{g2[Y]-30}', 'edge', 'beat', 2.4)
t(g1[X] + 10, 338, 'VRRP', 10.5, C['muted'])
t(g1[X] + 10, 352, 'ทุก 1 วิ', 10.5, C['muted'])
a1, a2 = N['app1'], N['app2']
link(f'M{g1[X]+26} {g1[Y]}H{a1[X]-26}', 'app')
link(f'M{g1[X]+26} {g1[Y]+6}C{g1[X]+120} {g1[Y]+6} {a2[X]-110} {a2[Y]} {a2[X]-26} {a2[Y]}', 'app', width=1.8)
link(f'M{g2[X]+26} {g2[Y]}H{a2[X]-26}', 'app', 'standby')
link(f'M{g2[X]+26} {g2[Y]-6}C{g2[X]+120} {g2[Y]-6} {a1[X]-110} {a1[Y]} {a1[X]-26} {a1[Y]+4}', 'app', 'standby', 1.6)
t(701, 132, 'REST: least_conn', 10.5, C['muted'], anchor='middle')
t(701, 146, 'hub/socket: sticky', 10.5, C['muted'], anchor='middle')
db, ci, old = N['db'], N['ci'], N['old']
link(f'M{a1[X]+26} {a1[Y]}C{a1[X]+130} {a1[Y]} {db[X]-120} {db[Y]} {db[X]-26} {db[Y]-4}', 'data')
link(f'M{a2[X]+26} {a2[Y]}C{a2[X]+130} {a2[Y]} {db[X]-120} {db[Y]} {db[X]-26} {db[Y]+4}', 'data')
t(958, 248, 'SQL · Redis', 10.5, C['muted'], anchor='middle')
t(958, 262, 'RabbitMQ · NFS', 10.5, C['muted'], anchor='middle')
link(f'M{ci[X]-26} {ci[Y]}C{ci[X]-140} {ci[Y]} {a1[X]+90} {a1[Y]-40} {a1[X]+18} {a1[Y]-18}', 'ci', 'deploy', 1.8,
     label='ssh deploy', lx=960, ly=96)

# ------------------------------------------------------------------ nodes + labels
glyph_node(*u, 'users'); label(u[X], u[Y] + 44, 'ผู้ใช้', 'HTTPS 443', 'เว็บ, แอป, LINE', 'old')
glyph_node(*cf, 'cloud'); label(cf[X], cf[Y] + 44, 'Cloudflare', 'proxied', 'SSL Full (strict)', 'old')
glyph_node(*rt, 'router'); label(rt[X], rt[Y] + 44, 'Router', 'NAT 80/443', 'ไป VIP หลัง cutover', 'old')

socket(*vip, 'edge'); label(vip[X], vip[Y] + 50, 'VIP', '192.168.88.100', 'เช็กเว็บจริงทุกนาที', 'edge')
socket(*g1, 'edge'); label(g1[X], g1[Y] + 50, 'erp-gw-01', '192.168.88.101', 'MASTER · nginx', 'edge')
socket(*g2, 'edge'); label(g2[X], g2[Y] + 50, 'erp-gw-02', '192.168.88.102', 'BACKUP · nginx', 'edge')

for key, name, ip, role in [('app1', 'erp-app-01', '192.168.88.111', 'manager'), ('app2', 'erp-app-02', '192.168.88.112', 'worker')]:
    x, y = N[key]
    socket(x, y, 'app')
    label(x, y + 50, name, ip, role, 'app')
    cy = y + 104
    for row in (['erpapp 8284'], ['erpapi 6334', '6344'], ['chat-api 6335']):
        w = sum(12 + len(r) * 6.4 for r in row) + 5 * (len(row) - 1)
        nx = x - w / 2
        for r in row:
            nx = chip(nx, cy, r, 'app')
        cy += 22
t(N['app1'][X], N['app1'][Y] + 172, 'ticker ×1 ทั้ง cluster', 10.5, C['muted'], anchor='middle')

socket(*db, 'data'); label(db[X], db[Y] + 50, 'erp-db-01', '192.168.88.12', '/srv บน iSCSI (NAS)', 'data')
cy = db[Y] + 104
for svc, port in [('SQL Server Express', '1433'), ('Redis', '6379'), ('RabbitMQ', '5672'), ('NFS erp-files', '2049')]:
    t(db[X] - 78, cy, svc, 11.5, C['ink'], 600)
    chip(db[X] + 52, cy, port, 'data')
    cy += 21

socket(*ci, 'ci'); label(ci[X] + 40, ci[Y] - 6, 'erp-ci-01', '192.168.88.131', 'Jenkins 8110', 'ci', anchor='start')

glyph_node(*old, 'legacy'); label(old[X] + 32, old[Y] - 6, 'เครื่องเดิม', '192.168.88.11', 'app 3030 · n8n 5678', 'old', anchor='start')
t(old[X] + 32, old[Y] + 42, 'gateway ส่งต่อให้', 11, C['muted'])
t(old[X] + 32, old[Y] + 58, 'Zabbix 192.168.88.21', 11, C['muted'])

# ------------------------------------------------------------------ legend
lx, ly = 34, 560
a(f'<rect x="{lx-12}" y="{ly-22}" width="330" height="104" rx="12" fill="{C["bg"]}" fill-opacity="0.7" stroke="{C["grid"]}"/>')
for i, (col, txt) in enumerate([('#12A15A', 'ปกติ'), ('#D92D20', 'มีปัญหา'), ('#8A94A0', 'ปิด / ซ่อมบำรุง')]):
    cx = lx + 6 + i * 104
    a(f'<circle cx="{cx}" cy="{ly-4}" r="6" fill="{col}"/>')
    t(cx + 12, ly, txt, 11, C['ink'])
for i, (kind, txt) in enumerate([('solid', 'เส้นทางหลัก'), ('standby', 'สำรอง (failover)'), ('beat', 'heartbeat (VRRP)'), ('deploy', 'deploy')]):
    xx = lx + (i % 2) * 160
    yy = ly + 24 + (i // 2) * 22
    tier = 'ci' if kind == 'deploy' else 'muted'
    link(f'M{xx} {yy-4}H{xx+30}', tier, kind, 2)
    t(xx + 38, yy, txt, 11, C['muted'])
t(lx - 6, ly + 74, 'STACK_MODE=test จนถึงวัน cutover', 10.5, C['dim'])

a('</svg>')
print('\n'.join(o))
