# battery-gauge — MU5120 软件电量计

针对 MU5120 固件电量锁死 50% 缺陷（电池档案 LUT 空表，详见仓库根目录 `MU5120电池问题报告.md`）的替代方案：在设备上以极低开销运行库仑积分电量计，并通过 HTTP 8888 端口输出实时数据。

## 设备端部署位置

`/cache/battery-gauge/`（cache 分区，恢复出厂不清除）

```
gauge.sh              电量计算主循环（5s 采样，库仑积分 + OCV 锚点校准）
respond.sh            HTTP 响应器（备用：systemd socket-activation 方案）
install.sh            rootfs 可写窗口内的一键持久化安装脚本
busybox / busybox-extras / ld-musl-armhf.so.1   Alpine armhf 运行时（不入库）
units/                systemd 单元文件
state.json            实时输出（由 gauge 循环每 5s 原子重写）
```

## 访问接口

```
http://<设备IP>:8888/state.json
```

返回格式化 JSON（UTF-8，含中文字段）：

```json
{
  "soc": 62.98,
  "soc_bar": "█████████████░░░░░░░",
  "voltage_mv": 4359,
  "current_ma": 1919,
  "power_w": 8.4,
  "temp_c": 34.7,
  "status": "Charging",
  "status_cn": "充电中",
  "summary": "电量约63%，充电中，当前功率约8.4W",
  "kernel_locked_percent": 50,
  "method": "coulomb+ocv-anchor",
  "interval_s": 5,
  "ts": 1792697192
}
```

## 启动（临时，重启后失效）

```bash
systemd-run --unit=battery-gauge --collect /bin/sh /cache/battery-gauge/gauge.sh
systemd-run --unit=battery-gauge-httpd --collect \
  /cache/battery-gauge/ld-musl-armhf.so.1 \
  /cache/battery-gauge/busybox-extras httpd -f -p 8888 -h /cache/battery-gauge
```

## 持久化

rootfs 平时为只读 UBI，`/etc` 不可写。重启后若 rootfs 恢复可写窗口，执行一次：

```bash
adb shell sh /cache/battery-gauge/install.sh
```

成功后由 systemd socket-activation 接管（空闲零开销），开机自启。

## 算法说明

- **库仑积分**：每 5s 读取 `current_now`，`ΔSOC = I×Δt / 9800mAh`（标称容量，可按实测老化调整 `gauge.sh` 中 `CAP_MAH`）
- **满充锚点**：充电中且电压 ≥4.35V、电流 <300mA（或 status=Full）→ 校准 100%
- **空电锚点**：放电且电压 ≤3.45V → 校准 1.5%
- **OCV 初始化**：无历史状态时按 4.45V 高压锂电 OCV-SOC 曲线估算（充电态减去内阻压降，按 25mΩ 估算）
- 状态持久化于 `/cache/battery-gauge/soc`（数值）与 `ts`（时间戳），重启不丢
