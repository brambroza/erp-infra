# render โดย scripts/10-gateway.sh → /etc/nginx/conf.d/00-upstreams.conf

# ---- Swarm: REST ผ่าน routing mesh กระจายตามโหลด ----
upstream erpapp {
    least_conn;
    server ${SVC1_IP}:8284 max_fails=3 fail_timeout=10s;
    server ${SVC2_IP}:8284 max_fails=3 fail_timeout=10s;
    keepalive 32;
}

upstream erpapi {
    least_conn;
    server ${SVC1_IP}:6334 max_fails=3 fail_timeout=10s;
    server ${SVC2_IP}:6334 max_fails=3 fail_timeout=10s;
    keepalive 64;
}

# ---- Swarm: WebSocket ต้อง sticky ไป container เดิม (port แบบ host mode) ----
upstream erpapi_hubs {
    hash $remote_addr consistent;
    server ${SVC1_IP}:6344 max_fails=2 fail_timeout=10s;
    server ${SVC2_IP}:6344 max_fails=2 fail_timeout=10s;
}

upstream chatapi {
    hash $remote_addr consistent;
    server ${SVC1_IP}:6335 max_fails=2 fail_timeout=10s;
    server ${SVC2_IP}:6335 max_fails=2 fail_timeout=10s;
}

# ---- บริการเดิมที่ยังเป็นเครื่องเดียว ----
upstream legacy_app  { server ${LEGACY_IP}:3030; }     # app.nisolution.co.th
upstream n8n         { server ${LEGACY_IP}:5678; }
upstream zbx_ws      { server ${LEGACY_IP}:10053; }    # api-zabbix /web-service/
upstream zbx_web     { server ${ZBX_HOST}:3032; }
upstream zbx_api     { server ${ZBX_HOST}:3089; }
upstream zbx_monitor { server ${ZBX_HOST}:8080; }
