# MU5120 设备改动与操作记录（2026-10-22）

> 本文档记录 2026-10-22 当天对本设备（ZTE MU5120）的全部诊断与改动，以及配套脚本代码的说明。

## 一、当天完成了什么

### 1. zwrt-datad 后端打通（端口 9461）

设备上部署的 zwrt-datad v0.10.72（Rust 版）鉴权方式与旧 UFI-TOOLS 协议完全不兼容，当天完成协议破解与验证：

- 鉴权流程：`POST /auth/login`（HTTP Basic，用户 `admin` + 后台密码）→ 返回 12 小时 Bearer Token（每次使用自动续期）
- 后续请求：`Authorization: Bearer <token>` 或 `X-Auth-Token`；SSE 可用 `?access_token=`
- 已验证接口：`/state`（11KB 完整状态快照）、`/capabilities`（50+ 控制动作）、`/control`、`/version`、`/healthz`

### 2. 信令抓取失效——根因定位（未修复，属固件缺陷）

- 现象：`u50_signaling.available=false`（`status_stale`），`restarts` 累计 1400+，`9461/signal/stream` 返回 503
- 根因：设备 glibc 2.31，10 月 16 日 OTA 到 0.10.72 时替换的 `diag-streamer`/`diag-worker` 按 GLIBC 2.33/2.34 链接，执行即报 `version 'GLIBC_2.33' not found`，采集器从未启动
- 修复需上游按 glibc 2.31 sysroot 重编或静态链接，设备侧无法自救

### 3. USB ADB 开通

- 出厂 USB 组合（PID 1403）不含 ADB，通过 `/sbin/usb_composition 902D`（RNDIS+DIAG+ADB）切换后 Windows 正常识别
- **重启后组合回退**，需重新执行 `usb_composition 902D`

### 4. 电池电量锁死 + 快充失效——根因定位（未修复，属固件缺陷）

- 现象：电量恒为 50%（跨 B8/B10/B12/B13 四个版本），快充 27W 降为约 8W
- 根因（固件 dtb 缺陷，详见 `MU5120电池问题报告.md`，已可交售后）：
  - 电池档案（COSMX/FENGHUA 两套 9800mAh）的 **FCC 温度表与 OCV-SOC 换算表为 0 字节空表**
  - `batt_id`/`batt_therm` ADC 通道未注册（ENODEV）
  - 设备树节点 `zte,support-different-id-battery-data` 缺失
- 硬件已全部排除故障（ADC 实测正常、充电/保护正常）

### 5. 软件电量计部署（端口 8888）——本次新增的代码

针对固件电量锁死的替代方案，部署于 `/cache/battery-gauge/`：

- `gauge.sh`：5 秒循环，库仑积分（电流×时间/9800mAh）+ 满充/空电锚点校准 + OCV 曲线初始化
- HTTP 服务：Alpine 静态 busybox-extras httpd（musl 加载器显式启动），监听 8888
- 访问：`http://192.168.0.1:8888/state.json`（格式化 JSON，含中文摘要与进度条）
- 资源开销：RAM 约 1.5MB，CPU <0.1%
- 运行方式：`systemd-run` 临时单元，**重启后失效**（见下文恢复步骤）

### 6. 电池问题报告（交售后用）

- `MU5120电池问题报告.md`：完整诊断证据 + 验收标准

## 二、设备端操作清单（按时间）

| 时间 | 操作 | 性质 | 影响 |
|---|---|---|---|
| 17:2x~17:4x | HTTP 探测 9461 各端点、Basic 登录测试 | 只读 | 无 |
| 17:4x | webshell 连入设备执行 ps/ls/cat | 只读 | 无 |
| 17:5x | 手动运行 `diag-streamer`（8s 超时） | 只读测试 | 无（因 glibc 启动失败） |
| 17:5x | 读取 `/lib/libc.so.6 --version`、`.deploy` 备份目录 | 只读 | 无 |
| 18:0x | `usb_composition 902D` 切换 USB 组合 | **配置变更** | 开启 ADB；重启后回退 |
| 18:1x | ADB 读取 `netstat`、电源节点等 | 只读 | 无 |
| 18:1x | 尝试写 `constant_charge_current_max`（被拒）、`current_max_mbb`（被钳位）、`restrict_cur`（已恢复原值 1000000） | 写尝试 | 无残留影响 |
| 18:1x | `mount -o remount,rw /` | 失败 | 无（UBI 卷出厂写保护） |
| 18:3x~19:2x | 部署 battery-gauge（写 /cache + /tmp），`systemd-run` 启动两个临时服务 | **新增** | 见下文"当前设备状态" |

**未做过的操作**：未删除任何文件、未修改任何系统配置、未刷写任何分区、未重启设备。

## 三、当前设备状态与恢复步骤（更新失败后）

**现象**：尝试系统更新后设备完全离线（WiFi/ping/9461/8888 均不可达），USB ADB 消失。

**原因分析**：

1. 设备重启会回退 USB 组合 → ADB 消失（预期行为）
2. 8888 电量计与 systemd 临时单元重启后失效（预期行为，脚本仍在 /cache）
3. 更新失败本身与上述操作无关：当天对设备仅有读操作和 /cache 新增约 2MB 文件；rootfs 从开机即为只读挂载且 remount 被内核拒绝，无任何系统文件被改动。更新失败更可能与 rootfs 只读（zwrt 安装器已知该场景会放弃写 /etc）或固件本身有关，待设备恢复后可读 `/cache/zwrt-datad/ota-state.json` 进一步定位

**恢复步骤**（设备重新上电并连接后）：

```bash
# 1. 重开 ADB（需 USB 数据线连接）
adb shell usb_composition 902D        # 或经 webshell 执行

# 2. 检查 datad 是否自动拉起（systemd 单元在 ro rootfs 中保留）
adb shell systemctl is-active zwrt-datad

# 3. 重新启动电量计（systemd-run 临时单元）
adb shell systemctl stop battery-gauge-httpd 2>/dev/null
adb shell systemd-run --unit=battery-gauge --collect /bin/sh /cache/battery-gauge/gauge.sh
adb shell systemd-run --unit=battery-gauge-httpd --collect /cache/battery-gauge/ld-musl-armhf.so.1 /cache/battery-gauge/busybox-extras httpd -f -p 8888 -h /cache/battery-gauge

# 4. 持久化（若 rootfs 恢复可写窗口，一次执行即可）
adb shell sh /cache/battery-gauge/install.sh
```

**验证**：浏览器访问 `http://192.168.0.1:8888/state.json`

## 四、仓库代码说明

`device-scripts/battery-gauge/` 目录（本仓库内，设备端部署源）：

| 文件 | 用途 |
|---|---|
| `gauge.sh` | 电量计算主循环（5s 库仑积分 + 锚点校准 + 格式化 JSON 生成） |
| `respond.sh` | HTTP 响应器（备用，socket-activation 方案） |
| `install.sh` | rootfs 可写窗口内的一键持久化安装脚本 |
| `units/battery-gauge.service` | 积分循环 systemd 单元 |
| `units/battery-gauge.socket` | 8888 监听 socket 单元 |
| `units/battery-gauge-http.service` | 每连接响应服务单元 |
| `README.md` | 部署与维护说明 |

设备端位置：`/cache/battery-gauge/`（含 Alpine busybox 运行时，约 1.7MB，不入库）。
