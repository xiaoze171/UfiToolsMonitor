#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""电池 CSV 体检：找出 gauge.sh 电量计算的异常"""
import csv, sys

path = r"D:/code/github/UfiToolsMonitor/battery-logs/cycle-20261025.csv"
rows = []
with open(path, encoding="utf-8") as f:
    for r in csv.DictReader(f):
        rows.append({
            "iso": r["ts_iso"], "ts": int(r["ts"]), "soc": float(r["soc"]),
            "mv": int(r["voltage_mv"]), "ma": int(r["current_ma"]),
            "w": float(r["power_w"]), "t": float(r["temp_c"]), "st": r["status"],
        })

print(f"总记录 {len(rows)} 条  {rows[0]['iso']} -> {rows[-1]['iso']}")

# 1. SOC 大跳变（相邻记录 |dSoc| > 8%，排除 1.5% 地板钳制和满充锚点）
print("\n[1] SOC 大跳变（|Δ|>8%，非 100% 锚点、非 1.5% 地板）")
for a, b in zip(rows, rows[1:]):
    d = b["soc"] - a["soc"]
    anchors = (a["soc"] in (0.0, 100.0)) or (b["soc"] in (0.0, 100.0))
    floors = (a["soc"] <= 1.6) or (b["soc"] <= 1.6)
    if abs(d) > 8 and not anchors and not floors:
        print(f"  {a['iso']} soc={a['soc']:7.2f} mv={a['mv']} ma={a['ma']:6d} {a['st']:<12}"
              f" -> {b['iso']} soc={b['soc']:7.2f} mv={b['mv']} ma={b['ma']:6d} {b['st']:<12} dSoc={d:+.2f}")

# 2. 库仑一致性：每段 ΔSoc 对应的电量 vs 实际电流积分
#    ΔmAh_actual = |ma| * dt/3600 ; ΔmAh_implied = |dSoc|/100 * 9800
print("\n[2] 库仑一致性（按状态分段统计）")
from collections import defaultdict
seg = defaultdict(lambda: [0, 0.0, 0.0])  # st -> [n, mAh_actual, mAh_implied]
for a, b in zip(rows, rows[1:]):
    dt = b["ts"] - a["ts"]
    if dt <= 0 or dt > 600:
        continue
    m = (a["st"], b["st"])
    if a["st"] != b["st"]:
        continue
    mAh_act = abs(a["ma"] + b["ma"]) / 2 * dt / 3600.0
    mAh_imp = abs(b["soc"] - a["soc"]) / 100 * 9800
    s = seg[a["st"]]
    s[0] += 1; s[1] += mAh_act; s[2] += mAh_imp
for st, (n, act, imp) in seg.items():
    if act > 50:
        ratio = imp / act if act else 0
        print(f"  {st:<12} n={n:5d} 实际流过={act:9.1f}mAh SOC变化折算={imp:9.1f}mAh 比值={ratio:.3f}")

# 3. 地板钳制触发（mv<=3450 时 SOC 被强设 1.5）
print("\n[3] 3450mV 地板钳制触发次数")
fl = [r for r in rows if r["soc"] == 1.5 and r["st"] == "Discharging"]
print(f"  共 {len(fl)} 条", end="")
if fl:
    print(f"  首次 {fl[0]['iso']}  末次 {fl[-1]['iso']}")

# 4. 充满锚点（soc=100）次数与上下文
print("\n[4] 满充锚点(soc=100)上下文")
fulls = [r for r in rows if r["soc"] == 100.0]
if fulls:
    print(f"  共 {len(fulls)} 条  首次 {fulls[0]['iso']} ({fulls[0]['st']}, {fulls[0]['mv']}mV)")

# 5. 高温与大电流
print("\n[5] 极值")
tmax = max(rows, key=lambda r: r["t"])
imax = max(rows, key=lambda r: abs(r["ma"]))
print(f"  最高温度 {tmax['t']}℃ @ {tmax['iso']} (soc={tmax['soc']}, {tmax['st']})")
print(f"  最大电流 {imax['ma']}mA @ {imax['iso']} (soc={imax['soc']}, mv={imax['mv']}, {imax['st']})")

# 6. 时间线概览：状态切换段
print("\n[6] 状态段概览（首尾SOC/电压）")
segs = []
cur = None
for r in rows:
    if cur is None or cur["st"] != r["st"]:
        if cur: segs.append(cur)
        cur = {"st": r["st"], "start": r, "end": r, "n": 1}
    else:
        cur["end"] = r; cur["n"] += 1
if cur: segs.append(cur)
for s in segs:
    a, b = s["start"], s["end"]
    print(f"  {a['iso']} -> {b['iso']}  {s['st']:<12} n={s['n']:5d}  soc {a['soc']:6.2f}->{b['soc']:6.2f}  mv {a['mv']}->{b['mv']}")

# 7. 放电段净消耗 vs SOC 降幅（整段核算）
print("\n[7] 整段核算：放电段 电流积分 vs SOC 折算")
for s in segs:
    if s["st"] != "Discharging" or s["n"] < 10:
        continue
    sub = [r for r in rows if s["start"]["ts"] <= r["ts"] <= s["end"]["ts"]]
    mAh = 0.0
    for a, b in zip(sub, sub[1:]):
        dt = b["ts"] - a["ts"]
        if 0 < dt <= 600:
            mAh += abs(a["ma"] + b["ma"]) / 2 * dt / 3600.0
    d_soc = abs(sub[-1]["soc"] - sub[0]["soc"])
    imp = d_soc / 100 * 9800
    if mAh > 100:
        print(f"  {s['start']['iso']}~{s['end']['iso']}  放出={mAh:8.1f}mAh  SOC降幅折算={imp:8.1f}mAh  Δsoc={s['start']['soc']:.2f}->{s['end']['soc']:.2f}")
