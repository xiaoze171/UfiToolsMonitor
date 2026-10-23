#!/bin/sh
# 兼容入口（旧命令仍可继续用）：
#   adb shell sh /cache/battery-gauge/install.sh
#
# 原版 install.sh 已由 start-88.sh 取代——旧版把采样周期写死为 10 秒，
# 与「每 5 秒回写内核 capacity」不匹配，也缺少启动后的状态自检。
# 本文件仅做转发，实际逻辑全部在 start-88.sh。

DIR=$(dirname "$0")
exec sh "$DIR/start-88.sh" "$@"
