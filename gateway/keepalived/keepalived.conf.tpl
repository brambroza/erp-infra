# render โดย scripts/10-gateway.sh (envsubst) — ห้ามแก้ไฟล์บนเครื่องตรง ๆ
global_defs {
    router_id ${ROLE}
    script_user root
    enable_script_security
    vrrp_garp_master_refresh 60
}

vrrp_script chk_nginx {
    script "/usr/bin/curl -fsS -o /dev/null --max-time 1 http://127.0.0.1:8081/healthz"
    interval 1          # เช็กทุก 1 วินาที ล้ม 2 ครั้งติด = ย้าย VIP (ทดสอบจริงที่ interval 2 ใช้เวลา ~6 วินาที)
    fall 2
    rise 2
    weight -30          # erp-gw-01: 110 → 80 (ต่ำกว่า erp-gw-02 = 100) VIP จึงย้าย
}

vrrp_instance VI_ERP {
    state BACKUP
    interface ${IFACE}
    virtual_router_id 51        # ต้องไม่ซ้ำกับ VRRP อื่นใน network
    priority ${PRIORITY}
    advert_int 1
    unicast_src_ip ${SELF_IP}
    unicast_peer {
        ${PEER_IP}
    }
    authentication {
        auth_type PASS
        auth_pass ${VRRP_PASS}
    }
    virtual_ipaddress {
        ${VIP}/${NET_PREFIX} dev ${IFACE}
    }
    track_script {
        chk_nginx
    }
    notify /usr/local/bin/gw-notify.sh
}
