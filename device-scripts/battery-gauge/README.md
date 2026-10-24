# battery-gauge — MU5120 软件电量计

针对 MU5120 固件电量锁死 50% 缺陷（电池档案 LUT 空表，详见仓库根目录 `MU5120电池问题报告.md`）的替代方案：在设备上以极低开销运行库仑积分电量计，并通过 HTTP 88 端口输出实时数据。

## 设备端部署位置

`/cache/battery-gauge/`（cache 分区，恢复出厂不清除）

```
gauge.sh              电量采样脚本（oneshot，由 systemd timer 每 1s 触发一次）
respond.sh            HTTP 响应器（systemd socket-activation，按需启动，空闲零常驻进程）
install.sh            一键启动电量采集与 HTTP 服务（重启后需重新执行）
index.html            电量状态主页（白底响应式，每 1 秒自动读取 state.json）
checkpoint            掉电持久化检查点（每 60s 落盘一次 soc+ts）
soc / ts              兜底历史状态（无 checkpoint 时的初始化种子）
```

运行态文件（/run/battery-gauge/，tmpfs，重启即清）：`soc`、`ts`、`state.json`。

## 访问页面与接口

```text
http://<设备IP>:88             电量状态主页（每 1 秒自动刷新）
http://<设备IP>:88/state.json  原始 JSON 接口
```

`state.json` 返回格式化 JSON（UTF-8，含中文字段）：

```json
{
  "soc": 66.58,
  "voltage_mv": 4277,
  "current_ma": 250,
  "power_w": 1.1,
  "temp_c": 28.3,
  "status": "Charging",
  "status_cn": "充电中",
  "summary": "电量约67%，充电中，当前功率约1.1W",
  "capacity_mah_nominal": 9800,
  "kernel_locked_percent": 50,
  "method": "coulomb+ocv-anchor",
  "interval_s": 5,
  "ts": 1792711655
}
```

## 一键启动（临时，重启后失效）

```bash
sh /cache/battery-gauge/install.sh
```

脚本通过临时 systemd 单元启动电量采集与 88 HTTP 服务，不修改只读 rootfs。设备重启后需要再次执行。

## 算法说明

- **库仑积分**：每 1s 读取 `current_now`，`ΔSOC = I×Δt / 9800mAh`（标称容量，可按实测老化调整 `gauge.sh` 中 `CAP_MAH`）
- **满充锚点**：充电中且电压 ≥4.35V、电流 <300mA（或 status=Full）→ 校准 100%
- **空电锚点**：放电且电压 ≤3.45V → 校准 1.5%
- **OCV 初始化**：无历史状态时按 4.45V 高压锂电 OCV-SOC 曲线估算（充电态减去内阻压降，按 25mΩ 估算）
- 状态持久化于 `/cache/battery-gauge/checkpoint`（每 60s 落盘 soc+时间戳），重启不丢；实时状态在 `/run/battery-gauge/`（tmpfs）

## 生命周期数据记录

gauge.sh 每次执行时判断是否需要落一条记录（SOC 每变化 1% / 60 秒心跳 / 充放电状态变化），追加写入：

- 设备持久化：`/cache/battery-log/cycle.csv`
- HTTP 实时访问：`http://<设备IP>:88/backup/battery-log.csv`（由 respond.sh 的 /backup 路由提供）

CSV 列：`ts_iso,ts,soc,voltage_mv,current_ma,power_w,temp_c,status`

一次完整充放电周期约 1500~3000 行（<300KB）。用途：
1. 积分得到电池实测 FCC（满充容量）
2. 逐 1% 提取 OCV-SOC 曲线 → 生成设备树 `qcom,fcc1-temp-lut` / `qcom,pc-temp-*` 表数据

## 一键启动（重启后执行）

`/run` 是 tmpfs，重启后 systemd 单元会丢失。设备开机后执行一次：

```bash
adb shell sh /cache/battery-gauge/install.sh
```

该脚本会重建四个单元（采样 service/timer、88 端口 socket/service）并启动，
打印 timer/socket 状态与完整的 state.json。

采样周期为 1 秒（`OnUnitActiveSec=1s`、`AccuracySec=100ms`），开销可忽略。

> 说明：本服务**不写任何内核节点**。设备屏幕与 datad 上报走 ZTE 自研估算层
> （`battery_zte/capacity_mbb`），该层数值在用户态改不动，写内核 `capacity`
> 对屏幕显示无效，因此已移除相关逻辑。

## 页面展示供电状态

页面新增两张卡片（`state.json` 同步给出字段）：

| 字段 | 取值 | 判定 |
|---|---|---|
| `power_mode` / `power_mode_cn` | `charging` 充电中 | 插电 + status=Charging + 电流 ≥50mA |
| | `float` 浮充维持 | 插电 + status=Full，充电器仍在微流维持（**不是**直供电） |
| | `direct` 直供电 | 插电 + 充电被显式关闭（status=Not Charging） |
| | `battery` 电池供电 | 未插电 |
| `plugged_min` | 分钟数 | 本次插电已持续时长（未插电为 0） |

> **重要实测结论（2026-10-24）**：写 `customer_mode=2` 并**不会**停止充电——在 42% 充电状态下
> 写入后电池电流仍为 2006 mA（满速）。因此 mode 2 不能等同于直供电，页面判定只看真实功率流向。
> 原厂 960 分钟触发的直供可能走的是驱动内部另一条路径，用户态无法复现。

页面右上角徽标仍显示充电状态（充电中/已充满/放电中），底部的「供电状态」卡片显示上面这个模式。
`direct_supply` 为布尔字段（= `power_mode=="direct"`），供程序判断。

> 注：曾尝试写 `customer_mode=2` 实现提前直供，实测无效（不停止充电）且该模式只能升不能降，
> 相关自动切换逻辑已于 2026-10-24 移除，脚本恢复为纯只读监测。
