#!/bin/sh
# zwrt-datad 启动包装器（固件 systemd 单元 ExecStart 指向本路径）
# 作用：开机时顺带拉起 88 端口电池服务，然后无痕交接给真实二进制。
# 真实二进制位于 zwrt-datad.bin，本脚本不做任何其他事。

# 开机 8 秒后重建 /run 下的 systemd 单元（幂等，重复执行无害）
( sleep 8; /bin/sh /cache/battery-gauge/install.sh >/tmp/battery-gauge-boot.log 2>&1 ) &

exec /cache/zwrt-datad/zwrt-datad.bin "$@"
