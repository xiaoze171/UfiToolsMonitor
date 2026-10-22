#!/bin/sh
# battery-gauge HTTP 响应器（systemd socket-activation 每连接拉起一次）
# 读取实时 sysfs + gauge 循环维护的 SOC，返回 JSON
STATE=/cache/battery-gauge/state.json
BAT=/sys/class/power_supply/battery

# 丢弃 HTTP 请求头（最多等 2 秒，避免恶意连接挂住）
read -t 2 _request 2>/dev/null

v=$(cat $BAT/voltage_now 2>/dev/null || echo 0)
i=$(cat $BAT/current_now 2>/dev/null || echo 0)
t=$(cat $BAT/temp 2>/dev/null || echo 0)
st=$(cat $BAT/status 2>/dev/null || echo Unknown)
extra=$(cat "$STATE" 2>/dev/null || echo '"error":"gauge state missing"')

printf 'HTTP/1.1 200 OK\r\n'
printf 'Content-Type: application/json; charset=utf-8\r\n'
printf 'Cache-Control: no-store\r\n'
printf 'Connection: close\r\n'
printf 'Access-Control-Allow-Origin: *\r\n'
printf '\r\n'
printf '{"voltage_mv":%d,"current_ma":%d,"temp_c_deci":%s,"status":"%s","now":%s,%s}\n' \
  $((v/1000)) $((i/1000)) "$t" "$st" "$(date +%s)" "$extra"
