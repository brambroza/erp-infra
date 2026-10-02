#!/usr/bin/env bash
# keepalived เรียกเมื่อสถานะเปลี่ยน: $1=type $2=name $3=state $4=priority
logger -t keepalived-notify "$(hostname) VIP state -> ${3:-?} (priority ${4:-?})"
# ต่อยอด: ส่ง LINE / webhook / Zabbix trapper ตรงนี้
