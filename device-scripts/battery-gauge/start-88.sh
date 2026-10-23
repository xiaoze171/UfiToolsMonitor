#!/bin/sh
# 兼容别名：主入口是 install.sh（历史命令，保持可用）。
#   等价命令：adb shell sh /cache/battery-gauge/install.sh

DIR=$(dirname "$0")
exec sh "$DIR/install.sh" "$@"
