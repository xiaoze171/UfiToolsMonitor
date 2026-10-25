#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""逐点核对：每两个相邻记录，SOC位移折算mAh vs 电流积分mAh"""
import csv

path = r"D:/code/github/UfiToolsMonitor/battery-logs/cycle-20261025.csv"
rows = []
with open(path, encoding="utf-8") as f:
    for r in csv.DictReader(f):
        rows.append((r["ts_iso"], int(r["ts"]), float(r["soc"]), int(r["voltage_mv"]),
                     int(r["current_ma"]), r["status"]))

print("时间                  dt    SOC位移mAh  电流积分mAh  比率   soc     ma     st")
bad = []
for a, b in zip(rows, rows[1:]):
    dt = b[1] - a[1]
    if dt <= 0 or dt > 600 or a[5] != b[5] or a[5] != "Discharging":
        continue
    imp = abs(b[2] - a[2]) / 100 * 9800          # SOC 位移折算
    act = abs(a[4] + b[4]) / 2 * dt / 3600.0     # 电流积分
    if act < 5:   # 过小的段无意义
        continue
    ratio = imp / act
    if ratio > 1.6 or ratio < 0.6:
        bad.append((a, b, dt, imp, act, ratio))

print(f"异常段数量: {len(bad)}")
for a, b, dt, imp, act, ratio in bad[:40]:
    print(f"{a[0]}  {dt:4d}s  {imp:9.1f}  {act:9.1f}  {ratio:5.2f}  soc {a[2]:6.2f}->{b[2]:6.2f}  {a[4]:6d}  {a[5]}")

# 按小时汇总比率
print("\n按小时汇总（Discharging， imp/act）:")
from collections import defaultdict
hb = defaultdict(lambda: [0.0, 0.0])
for a, b in zip(rows, rows[1:]):
    dt = b[1] - a[1]
    if dt <= 0 or dt > 600 or a[5] != "Discharging":
        continue
    imp = abs(b[2] - a[2]) / 100 * 9800
    act = abs(a[4] + b[4]) / 2 * dt / 3600.0
    h = a[0][:13]
    hb[h][0] += imp; hb[h][1] += act
for h in sorted(hb):
    imp, act = hb[h]
    if act > 20:
        print(f"  {h}时  imp={imp:8.1f}  act={act:8.1f}  ratio={imp/act:5.2f}")
