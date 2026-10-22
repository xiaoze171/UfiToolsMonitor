#!/bin/sh
# 启动低占用软件电量计：5 秒定时采样 + 88 端口按需 HTTP。
# 所有 systemd 单元只写入 /run，设备重启后消失，不修改只读 rootfs。

BASE=/cache/battery-gauge
UNIT_DIR=/run/systemd/system

fail() {
    echo "启动失败：$1" >&2
    exit 1
}

[ -f "$BASE/gauge.sh" ] || fail "缺少 $BASE/gauge.sh"
[ -f "$BASE/respond.sh" ] || fail "缺少 $BASE/respond.sh"
[ -f "$BASE/index.html" ] || fail "缺少 $BASE/index.html"
command -v systemctl >/dev/null 2>&1 || fail "系统不支持 systemd"
mkdir -p "$UNIT_DIR" || fail "无法创建临时单元目录"

# 停止旧版常驻服务，释放端口和常驻内存。
systemctl stop battery-gauge-httpd.service battery-gauge.service \
    battery-gauge.socket battery-gauge-http.socket \
    battery-gauge-sample.timer 2>/dev/null || true
systemctl reset-failed battery-gauge-httpd.service battery-gauge.service 2>/dev/null || true

cat > "$UNIT_DIR/battery-gauge-sample.service" <<'EOF'
[Unit]
Description=MU5120 software battery gauge sample
RequiresMountsFor=/cache

[Service]
Type=oneshot
ExecStart=/bin/sh /cache/battery-gauge/gauge.sh
Nice=10
IOSchedulingClass=idle
EOF

cat > "$UNIT_DIR/battery-gauge-sample.timer" <<'EOF'
[Unit]
Description=Sample MU5120 battery every 5 seconds

[Timer]
OnActiveSec=1s
OnUnitActiveSec=5s
AccuracySec=1s
Unit=battery-gauge-sample.service

[Install]
WantedBy=timers.target
EOF

cat > "$UNIT_DIR/battery-gauge-http.socket" <<'EOF'
[Unit]
Description=MU5120 battery page socket (port 88)

[Socket]
ListenStream=0.0.0.0:88
Accept=yes
MaxConnections=8
NoDelay=true

[Install]
WantedBy=sockets.target
EOF

cat > "$UNIT_DIR/battery-gauge-http@.service" <<'EOF'
[Unit]
Description=MU5120 battery HTTP response

[Service]
ExecStart=/bin/sh /cache/battery-gauge/respond.sh
StandardInput=socket
StandardOutput=socket
StandardError=journal
TimeoutStartSec=5s
EOF

systemctl daemon-reload || fail "systemd 重新加载失败"
systemctl start battery-gauge-sample.service || fail "首次采样失败"
systemctl start battery-gauge-sample.timer || fail "定时采样启动失败"
systemctl start battery-gauge-http.socket || fail "88 端口启动失败"

systemctl is-active --quiet battery-gauge-sample.timer || fail "定时采样状态异常"
systemctl is-active --quiet battery-gauge-http.socket || fail "HTTP socket 状态异常"

# 旧版运行时不再需要；若仍存在，保留到外部清理步骤处理。
echo "START-OK"
echo "访问：http://<设备IP>:88"
