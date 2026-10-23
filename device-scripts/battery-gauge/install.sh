#!/bin/sh
# MU5120 电池服务一键启动（88 端口页面 + 每秒采样）
#
# 设备重启后 /run 是 tmpfs，systemd 单元会丢失，执行本脚本即可全部恢复：
#   adb shell sh /cache/battery-gauge/install.sh
#
# 启动内容：
#   battery-gauge-sample.timer  → 每 1 秒执行 gauge.sh，刷新 /run/battery-gauge/state.json
#   battery-gauge-http.socket   → 88 端口按连接拉起 respond.sh（页面 / 与 /state.json）
#
# 不写任何内核节点：设备屏幕走 ZTE 自研估算层（battery_zte/capacity_mbb），
# 用户态改不动，故本服务只负责自成一体的软件电量计。

BASE=/cache/battery-gauge
RUN=/run/battery-gauge
SD=/run/systemd/system

fail() {
    echo "启动失败：$1" >&2
    exit 1
}

[ -f "$BASE/gauge.sh" ] || fail "缺少 $BASE/gauge.sh"
[ -f "$BASE/respond.sh" ] || fail "缺少 $BASE/respond.sh"
[ -f "$BASE/index.html" ] || fail "缺少 $BASE/index.html"
command -v systemctl >/dev/null 2>&1 || fail "系统不支持 systemd"
mkdir -p "$RUN" "$SD" || fail "无法创建运行目录"
chmod 755 "$BASE/gauge.sh" "$BASE/respond.sh" 2>/dev/null

# 清理旧版常驻服务，释放端口与常驻内存
systemctl stop battery-gauge-httpd.service battery-gauge.service \
    battery-gauge.socket 2>/dev/null || true
systemctl reset-failed battery-gauge-httpd.service battery-gauge.service 2>/dev/null || true

cat > "$SD/battery-gauge-sample.service" <<'EOF'
[Unit]
Description=MU5120 software battery gauge sample
RequiresMountsFor=/cache

[Service]
Type=oneshot
ExecStart=/bin/sh /cache/battery-gauge/gauge.sh
Nice=10
IOSchedulingClass=idle
EOF

cat > "$SD/battery-gauge-sample.timer" <<'EOF'
[Unit]
Description=Sample MU5120 battery every 1 second

[Timer]
OnActiveSec=1s
OnUnitActiveSec=1s
AccuracySec=100ms
Unit=battery-gauge-sample.service

[Install]
WantedBy=timers.target
EOF

cat > "$SD/battery-gauge-http.socket" <<'EOF'
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

cat > "$SD/battery-gauge-http@.service" <<'EOF'
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

# 先跑一次，避免页面首次打开是空数据
[ -r "$RUN/state.json" ] || sh "$BASE/gauge.sh" 2>/dev/null

systemctl restart battery-gauge-sample.timer 2>/dev/null || fail "定时采样启动失败"
systemctl restart battery-gauge-http.socket 2>/dev/null || fail "88 端口启动失败"

sleep 2

systemctl is-active --quiet battery-gauge-sample.timer || fail "定时采样状态异常"
systemctl is-active --quiet battery-gauge-http.socket || fail "88 端口状态异常"

echo "START-OK"
echo "timer  : $(systemctl is-active battery-gauge-sample.timer 2>/dev/null)"
echo "socket : $(systemctl is-active battery-gauge-http.socket 2>/dev/null)"
echo "--- state.json ---"
cat "$RUN/state.json" 2>/dev/null
echo
echo "页面: http://$(ip route get 1 2>/dev/null | grep -o 'src [0-9.]*' | cut -d' ' -f2):88/"
