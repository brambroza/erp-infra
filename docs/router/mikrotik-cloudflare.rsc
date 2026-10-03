# MikroTik: port forward 80/443 เข้า VIP และรับเฉพาะ IP ของ Cloudflare
# ใช้: แก้ WAN / VIP ให้ตรงของจริง แล้ว import หรือ copy ไปวางใน terminal
# :local ใช้ได้เฉพาะตอนวางทั้งก้อนพร้อมกัน

:local wan "ether1"
:local vip "192.168.88.100"

/ip firewall address-list
remove [find list=cloudflare]
:foreach n in={"173.245.48.0/20";"103.21.244.0/22";"103.22.200.0/22";"103.31.4.0/22";"141.101.64.0/18";"108.162.192.0/18";"190.93.240.0/20";"188.114.96.0/20";"197.234.240.0/22";"198.41.128.0/17";"162.158.0.0/15";"104.16.0.0/13";"104.24.0.0/14";"172.64.0.0/13";"131.0.72.0/22"} do={ add list=cloudflare address=$n }

/ip firewall nat
add chain=dstnat in-interface=$wan src-address-list=cloudflare protocol=tcp dst-port=443 action=dst-nat to-addresses=$vip to-ports=443 comment="erp https via cloudflare"
add chain=dstnat in-interface=$wan src-address-list=cloudflare protocol=tcp dst-port=80  action=dst-nat to-addresses=$vip to-ports=80  comment="erp http via cloudflare"

# DNS ภายใน: คนในออฟฟิศเข้า VIP ตรง ไม่ต้องอ้อมออก Cloudflare
/ip dns static
add name=erp.nisolution.co.th address=$vip
add name=api.nisolution.co.th address=$vip
add name=app.nisolution.co.th address=$vip
add name=n8n.nisolution.co.th address=$vip
add name=erp-vip address=$vip
