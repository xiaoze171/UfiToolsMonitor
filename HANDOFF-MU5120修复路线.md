# MU5120 修复任务交接文档

> 交接对象：下一个接手的 AI（或人类）。
> 本文档为 2026-10-25 的完整上下文快照。配套阅读：`DEVICE-CHANGES.md`（设备改动史）、`MU5120电池问题报告.md`（问题分析）、`.workbuddy/memory/`（逐日工作日志，其中 `2026-10-25.md` 最新）。

---

## 1. 任务目标

修复 ZTE MU5120 随身 WiFi 的两个由**同一根因**导致的问题：

1. **电量锁死 50%**（内核 QG 电量计无法工作）
2. **快充失效**（27W 档案不加载 → 降级 5V/2A ≈ 8W，电荷泵不工作）

**根因**（已确证）：boot 镜像 DTB 中电池 ID 的 `batt-id` 属性值为 20kΩ，但硬件 ADC 实际读数 0Ω → QG 驱动无法匹配任何电池档案（COSMX 20kΩ / FENGHUA 47kΩ）→ fastchg 6000mA/27W 参数不加载、FCC/SOC 无法计算、smb1394 电荷泵（chip_all_work=0）不使能。

**修复方案**：对 boot 镜像做 **2 字节补丁**（batt-id 20→0），刷回 mtd19 boot 分区。补丁版镜像已生成并验证。

**当前卡点**：mtd19 被内核写保护 + OTA 引擎刷写返回 -2。详见 §4/§5。

---

## 2. 设备概况与访问方式

| 项 | 值 |
|---|---|
| 型号 | ZTE MU5120（ZWRT 社区固件，u50pro 模板，zwrt-datad v0.10.72） |
| 系统 | QTI Linux sdxlemur，内核 5.4.226 armv7，glibc 2.31，非 Android |
| root | adb shell 即 root；webshell 也是 root |
| 局域网地址 | 192.168.0.1 |
| 88 端口 | 软件电量计页面（socket activation，**已实现开机自启**） |
| 9461 | datad API（LAN 侧），`POST /auth/login -u admin:111111` → `access_token`（12h） |
| 9460 | 本机端口（免鉴权），外部 9460 的 502 是干扰项勿混淆 |
| webshell | WebSocket `ws://192.168.0.1:9461/webshell`，子协议 `datad-webshell-v1, datad-auth.<token>`（**两个都要**），先发 text 帧 `{"type":"resize","cols":200,"rows":50}`，再发 binary 帧 `命令+\n`，结束发 `\x04`；现成客户端：`/tmp/webshell.py`（Git Bash 路径，Windows 实际路径 `C:\Users\xiaoze\AppData\Local\Temp\webshell.py`），用法 `python webshell.py <token> "<cmd>" <timeout>` |
| ADB 开启 | webshell 执行 `/sbin/usb_composition 902D`，约 6 秒后 `adb devices`（打印 `qcom_gadget/enabled` 报错无害）。**每次重启后回退 1403，需重开**。USB 线必须接 PC（接充电器永远不出 ADB） |
| 分区 | rootfs(ubi0:rootfs) 只读 remount 被拒；可写：/cache、/data、/etc_rw、/logfs、/persist；/run、/systemrw 是 tmpfs |

⚠️ **Git Bash 坑**：设备路径如 `/sbin/...` 会被转换成 `D:/app/...`，需 `MSYS_NO_PATHCONV=1`；但该变量会连本地脚本路径一起禁转换，本地脚本用 `cygpath -w` 转 Windows 路径。

---

## 3. 已完成的工作

1. **软件电量计**（88 端口）：库仑积分 + OCV 锚点 + 满充/空电锚点，1 秒刷新，实测精度 0.2%。数据记录 `/cache/battery-log/cycle.csv`，下载路由 `http://192.168.0.1:88/backup/battery-log.csv`
2. **88 端口开机自启**：`/cache/zwrt-datad/zwrt-datad` 是包装脚本（先拉起 `sh /cache/battery-gauge/install.sh` 重建 /run 单元，再 `exec zwrt-datad.bin`）；真实二进制为 `zwrt-datad.bin`（sha 前缀 ef03dcd4）。重启实测 45 秒自动上线。**不要把它当病毒删除**
3. **电量计算 bug 修复**（2026-10-25）：旧地板规则「放电且端电压≤3450mV → 强设 1.5%」在 6A 重载下误触发（内阻压降 ~300mV），导致 55%→1.5% 断崖。已改为 IR 补偿（`OCV = mv + |ma|×45mΩ ≤ 3400mV` 才触发），R_MOHM 25→45。库仑核心本身验证无误（逐小时比率 0.91~1.09）
4. **全量备份**：`备份/` 内 22 个 mtd 位级镜像 + 4 个文件级 tar + SHA256SUMS + BACKUP-MANIFEST.md。关键：`mtd19_boot.img`（旧版 boot d689c4bb）、`mtd19_boot_B12_new.img`（当前 boot 15b327f9，设备现状）
5. **OTA 容器格式逆向**（`device-scripts/ota/parse_package.py`）：magic `55AA5588` + 29 个条目（name 32 字节 + size u32 + start u32）+ 256B 签名块 + 尾部 32 字符 MD5。MD5 可重算 = 可伪造。原包 `OTA包/delta.package`（21,398,481B，sha1 前缀 1e59ba33）
6. **刷写引擎认知**：`zte_topsw_dua`（/usr/bin，systemd 常驻），命令 system/recovery/scout/standalone/split_delta，监听 UNIX socket `/tmp/MSG_ID_FOTA_VRM_DAEMON`，`/usr/bin/upd_util validate|update` 发指令。**双校验路径**：真实升级走 `validate_pack`（仅内部 MD5）✅已打通；scout 走 `zte_file_verify`（openssl RSA 验签）。**`/cache/delta.bin` 是门闸文件（= 包本体）**。引擎失败会自动重启设备（"scout failed, reboot now"），属正常现象
7. **引擎补丁**：`work/dua_patched2.bin`（sha 前缀 94713934，绕过签名校验的三处补丁：0x6944/0x6964/0x6966 NOP cbnz + movs r4,#0）。设备上 `/cache/dua_real/` 有副本；曾用 bind-mount 覆盖 /usr/bin/zte_topsw_dua（重启失效需重做）
8. **自制刷写包**：`OTA包/fix-boot-v4.package`（内含 256B 签名块 + 正确尾部 MD5，validate_pack 的 MD5_CALC=2e79a25c 已与包一致）。目标镜像 `work/boot_fixed.img`（sha 前缀 dff2d4f1，当前 boot 的 2 字节补丁版）
9. **写保护逆向**：内核模块 `zte_flash_protect`：17 条保护区表 + enable 开关（内核地址 0xb168d140）；存在解锁函数但**内核无任何调用者**；`/sys/class/zte_flash/write_protect` 是空操作幌子。boot(mtd19) 写入命令返回成功但内容不变（静默丢弃）；fota 分区可正常擦写

---

## 4. 当前卡点：OTA 引擎刷写返回 -2

现象：部署自制包到 `/cache/delta.bin` + 配套三件套 → `upd_util update` → 引擎接受包、进入刷写 → **写阶段返回 -2** → 失败。

两个假设（按可能性排序）：

- **假设 A（最可能）**：引擎对 mtd19 的写入同样被 `zte_flash_protect` 静默丢弃 → 引擎回读校验失败 → -2。即 -2 不是包格式问题，是写保护问题
- **假设 B**：包内 boot 条目需为 IMGDIFF2/NORMDIFF 差分格式（官方包的 boot.mld 是差分补丁），裸镜像不被写路径接受

---

## 5. 继续修复的路线（按推荐顺序）

### 路线 1：逆向 IMGDIFF2/NORMDIFF 差分格式（价值最高）

现成"三元组"可离线逆推官方差分格式，无需设备参与：

- 旧 boot：`备份/mtd19_boot.img`（d689c4bb）
- 官方差分补丁：`OTA包/extracted/boot.mld`
- 新 boot：`备份/mtd19_boot_B12_new.img`（15b327f9，= 三元组运算结果）

产出价值：
1. 完全理解引擎写镜像时期望的条目格式（解假设 B）
2. 可直接生成「当前 boot 15b327f9 → boot_fixed dff2d4f1」的极小差分补丁（只差 2 字节）
3. 用官方格式重打包 → validate_pack → 刷写

工具：`work/fdt.py`、`device-scripts/battery-gauge/{patch-dtb.py,fdt_parser.py}`、`device-scripts/ota/parse_package.py`。IMGDIFF2 是 Android boot_image_initializer / OTA 的标准格式，可参考 AOSP 源码 `bootable/recovery/applypatch/imgdiff.cpp` 与 `bsdiff` —— **先对照 AOSP 实现，可能不用从零逆**。

### 路线 2：确认 -2 与写保护的关系

- 反汇编引擎二进制（`OTA包/extracted/` 里有原版；设备 `/usr/bin/zte_topsw_dua`）找错误码表，定位 -2 的语义
- 刷写过程中监视 mtd19 是否变化：`watch -n 1 'sha256sum /dev/mtd19'`（或 dd 读回）
- 若确认写保护 → 进入路线 3

### 路线 3：解除 zte_flash_protect（按可行度排序）

1. **recovery 路径**：引擎支持 `recovery` 命令；recovery 镜像（`work/recovery_cur.img` 已提取）同样含 zte_flash_protect，但 **recovery 模式下 enable 状态未知**——若 recovery 内核不使能保护，走 recovery 刷写即可绕过。检查 recovery 镜像内模块初始化逻辑（`work/recovery_kernel.bin` 已解压）
2. **enable 开关**：内核地址 0xb168d140 的 enable 变量，排查是否有可达的修改通道：`/sys/module/zte_flash_protect/parameters/`、debugfs（`/sys/kernel/debug/`）、/proc 下相关节点
3. **自编内核模块**：内核 5.4.226 armv7，需要匹配 vermagic 与符号 CRC（Module.symvers），无源码树则难，列为下策
4. **引号内核解锁函数**：解锁函数存在于内核但无调用者，若有办法从可加载代码调用它（同 3）

### 路线 4：兜底 — 售后/外部途径

若内核层全部走不通：boot 分区保护在内核态，用户态无法绕过时，只能靠 (a) 官方售后全量包（官方不维护了）、(b) 高通 9008 EDL 模式（需短接/测试点，设备无 exposed EDL 触点信息）、(c) 等 ZWRT 社区出新固件。

### 刷写成功后的验证清单

```sh
adb shell sha256sum /dev/mtd19        # 应等于 dff2d4f1…（work/boot_fixed.img）
adb shell reboot
# 重启后：
adb shell cat /sys/class/power_supply/battery/batt_id    # 应有读数（非空/非0）
adb shell cat /sys/class/power_supply/battery/constant_charge_current_max   # 应为 6000000 (6A) 而非 2000000
adb shell cat /sys/class/power_supply/charger_zte/chip_all_work             # 应为 1
# 电量：kernel SOC 不再锁 50%；快充最高 27W（9V/3A 输入 + 电荷泵）
```

⚠️ 若 boot_fixed 有任何问题导致起不来：设备有 recovery 分区（mtd 内有 recovery_cur.img 备份），且我们已做全量 mtd 备份，可回滚 mtd19。**刷写前务必确认 `备份/SHA256SUMS` 完好**。

---

## 6. 禁区（违反会丢数据/变砖）

1. **`/etc_rw/restore`、`/data/restore`、`/logfs/restore` 三个目录是分区健康标记**，缺失会导致开机时对应分区被格式化——严禁删除或改名（`firmware-ubi-mount.sh` 逻辑）
2. **不要删除/覆盖 `/cache/zwrt-datad/zwrt-datad`**（包装脚本，承担 88 自启）与 `zwrt-datad.bin`（真实守护，webshell 通道）
3. `dd` 裸读 mtd2 (efs2) 会内核崩溃重启；读 efs 用 efsbak 分区
4. 写 boot 之外，不要尝试擦任何未备份的 mtd 分区；`备份/SHA256SUMS` 是回滚依据
5. webshell PTY 会损坏中文（显示 ???）、长行截断（≤480 字符/块）——传文件用 base64 逐块或 ADB push
6. 引擎刷写失败会自动重启设备，别在此时机再做并发操作

---

## 7. 关键文件索引（本仓库）

| 路径 | 说明 |
|---|---|
| `备份/mtd*.img`（22 个） | 全部分区位级镜像 + SHA256SUMS；mtd19 = boot |
| `备份/mtd19_boot.img` / `mtd19_boot_B12_new.img` | 旧 boot（d689c4bb）/ 当前 boot（15b327f9）——IMGDIFF2 三元组之二 |
| `备份/rootfs-files.tar.gz.part-00/01` | rootfs 文件级备份分卷（原文件 135MB 超 GitHub 单文件限制已分卷；还原：`cat rootfs-files.tar.gz.part-* > rootfs-files.tar.gz`，sha256 应为 c9a6ae7e…） |
| `OTA包/delta.package` | 官方 OTA 原包（拦截于真实升级） |
| `OTA包/extracted/` | 29 个组件；**boot.mld** 为官方 boot 差分补丁（三元组之三） |
| `OTA包/fix-boot-v4.package` | 自制刷写包（validate_pack 已通过，卡在写阶段 -2） |
| `work/boot_fixed.img` | 目标镜像：当前 boot 的 2 字节补丁版（dff2d4f1） |
| `work/dua_patched2.bin` | 签名绕过补丁版引擎（94713934） |
| `work/vmlinux.bin`、`work/kernel.bin` | 解压的内核（基址 0xb0008000），供反汇编 zte_flash_protect |
| `work/recovery_kernel.bin`、`work/recovery_cur.img` | recovery 侧（路线 3.1 用） |
| `work/analyze_cycle.py`、`work/analyze_p2p.py` | 电量 CSV 分析脚本（本次 bug 定位工具） |
| `work/datad_ws.py` | datad WebSocket 客户端（协议验证用，生产用 /tmp/webshell.py） |
| `device-scripts/battery-gauge/` | 电量计全部脚本（gauge.sh 为当前设备运行版） |
| `device-scripts/battery-gauge/zwrt-datad-wrapper.sh` | 88 自启包装脚本（设备 /cache/zwrt-datad/zwrt-datad） |
| `device-scripts/battery-gauge/service-control.sh` | datad 部署工具链（已适配 .bin 双路径校验） |
| `device-scripts/ota/parse_package.py` | OTA 容器解析器 |
| `MU5120电池问题报告.md` | 根因分析报告（已按"档案数据完整、真缺陷为 batt_id 通道"更正） |

---

## 8. 电量计现状（与修复任务并行，已稳定）

- **开机自启已解决**：重启后 45 秒内 88 端口自动上线，无需人工干预
- **SOC 断崖 bug 已修**（IR 补偿地板），设备当前 SOC 计数器已按事件链重建校回 50%，用户充电中，充满后满充锚点自动精确标定 100%
- **遗留**：gauge.sh 内置 OCV-SOC 对照表偏保守（37.5% 真实电量时表读 7%），仅影响重启后的冷启动初值，不影响运行精度；可通过一次受控放电重新标定
- boot 补丁刷写成功后，内核 QG 恢复，88 页面的 kernel_locked_percent 字段应从 50 变为真实值

---

## 9. 交接注意事项

- 本仓库托管在 GitHub（xiaoze171/UfiToolsMonitor），**可能是公开仓库**；文档中的 admin/111111 为设备默认 Web 密码且服务仅限局域网，介意的话自行改密码后从文档移除
- 逐日细节（含每一次失败的现场记录）在 `.workbuddy/memory/2026-10-22.md` ~ `2026-10-25.md`，**接手前务必通读**
- 设备是用户日用机：大流量/高 CPU 操作（如全量 dd、gzip）注意告知用户；压测类操作用户可配合
- 用户偏好：不要 present_files 弹窗，回复以结论+差异为主，改了什么/判据/回归结果讲清楚即可
