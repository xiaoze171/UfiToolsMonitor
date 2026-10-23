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

## 内核电量同步（每 5 秒）

QG 因电池档案匹配失败（`batt_id` 读数为 0，不匹配 20kΩ/47kΩ 任一档案）而算不出 SOC，
其上报的 `capacity` 常年锁死 50。但该节点在 root 下**可写且写入持久**（QG 不会覆盖）。

gauge.sh 因此每 5 秒把软件电量计的 SOC 四舍五入后回写：

```
/sys/class/power_supply/battery/capacity   ← 真实 SOC（0~100 整数）
```

- 节流状态记在 `/run/battery-gauge/last-cap-sync`，采样仍是 1 秒一次
- 读回值写入 state.json 的 `kernel_capacity` 字段，`kernel_capacity_sync_s` 为同步周期
- 临时停用：`touch /cache/battery-gauge/no-cap-sync`（删除该文件即恢复）

注意：设备屏幕与 datad 上报走的是 ZTE 自研估算层（`battery_zte/capacity_mbb`），
不受本同步影响——该层数值用户态改不动，只能等固件修复。

## 一键启动（重启后执行）

`/run` 是 tmpfs，重启后 systemd 单元会丢失。设备开机后执行一次：

```bash
adb shell sh /cache/battery-gauge/start-88.sh
```

该脚本会重建四个单元（采样 service/timer、88 端口 socket/service）、启动它们，
并打印 timer/socket 状态、内核电量与完整的 state.json。

> 旧命令 `sh /cache/battery-gauge/install.sh` 仍可用：该文件现为兼容入口，
> 会直接转发到 `start-88.sh`（原版把它写死 10 秒采样，已废弃）。
