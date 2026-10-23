#!/bin/sh
# MU5120 电池服务一键启动（88 端口 + 电量同步）
#
# 用途：设备重启后 /run 是 tmpfs，systemd 单元会丢失。执行本脚本即可全部恢复：
#   - 采样器 battery-gauge-sample.timer（每 1 秒执行 gauge.sh，内部每 5 秒回写内核 capacity）
#   - 88 端口页面 battery-gauge-http.socket（访问 http://<设备IP>:88/）
#
# 用法： adb shell sh /cache/battery-gauge/start-88.sh
#        （或在设备终端直接 sh /cache/battery-gauge/start-88.sh）

BASE=/cache/battery-gauge
RUN=/run/battery-gauge
SD=/run/systemd/system

mkdir -p "$RUN" "$SD" || exit 1
chmod 755 "$BASE/gauge.sh" "$BASE/respond.sh" 2>/dev/null

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

systemctl daemon-reload

# 先跑一次，避免页面首次打开是空数据
[ -r "$BASE/state.json" ] || sh "$BASE/gauge.sh" 2>/dev/null

systemctl restart battery-gauge-sample.timer 2>/dev/null
systemctl restart battery-gauge-http.socket 2>/dev/null

sleep 2

echo "timer  : $(systemctl is-active battery-gauge-sample.timer 2>/dev/null)"
echo "socket : $(systemctl is-active battery-gauge-http.socket 2>/dev/null)"
echo "内核电量: $(cat /sys/class/power_supply/battery/capacity 2>/dev/null)%"
echo "--- state.json ---"
cat "$RUN/state.json" 2>/dev/null
echo
echo "页面: http://$(ip route get 1 2>/dev/null | grep -o 'src [0-9.]*' | cut -d' ' -f2):88/"
