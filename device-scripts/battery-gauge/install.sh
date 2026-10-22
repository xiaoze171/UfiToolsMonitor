#!/bin/sh
# 在 rootfs 可写的开机窗口内执行（重启后尽快: adb shell sh /cache/battery-gauge/install.sh）
BASE=/cache/battery-gauge
mount -o remount,rw / 2>/dev/null || { echo "rootfs 不可写，稍后重试"; exit 1; }
cp $BASE/units/battery-gauge.service $BASE/units/battery-gauge.socket $BASE/units/battery-gauge-http.service /etc/systemd/system/
systemctl daemon-reload
systemctl disable --now battery-gauge-httpd 2>/dev/null
systemctl enable --now battery-gauge.service battery-gauge.socket
mount -o remount,ro / 2>/dev/null
echo INSTALL-OK
