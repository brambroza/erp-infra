#!/usr/bin/env bash
# ค่าที่ Zabbix agent ถาม (เรียกผ่าน UserParameter ใน erp-infra.conf) — ติดตั้งโดย scripts/50-zabbix.sh
# อ่านอย่างเดียว ไม่ต้องใช้ sudo
VIP="__VIP__"
case "${1:-}" in
  vip)        # 1 = เครื่องนี้ถือ VIP อยู่, 0 = ไม่ได้ถือ
    ip -o -4 addr show | grep -q " ${VIP}/" && echo 1 || echo 0 ;;
  certdays)   # จำนวนวันก่อน cert หมดอายุ อ่านจาก nginx ตรง ๆ (-1 = อ่านไม่ได้)
    end=$(echo | timeout 5 openssl s_client -connect 127.0.0.1:443 -servername "${2:-erp.nisolution.co.th}" 2>/dev/null \
          | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    if [ -n "$end" ]; then echo $(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 )); else echo -1; fi ;;
  *) echo "ใช้: $0 vip | certdays [domain]" >&2; exit 1 ;;
esac
