# MU5120：960 分钟长充模式调查

> 调查日期：2026-10-29。结论仅适用于下述 SHA256 对应的固件。本次提交仅记录只读调查，不实现自动切换或写入设备参数。

## 结论摘要

1. 当前固件默认周期为 **960 分钟，即 16 小时**。这条计时路径不是从 USB 插入就开始，而是连接电源后，驱动首次观察到 REAL_CAPACITY_MBB == 100 才开始计时。
2. “18 小时”不是这条路径的独立阈值。若从插电到驱动判满约需 2 小时，总时间可能约为 2 + 16 = 18 小时；这是对现象的解释，不是另一个已确认的 1080 分钟常量。
3. 计满后调用 zte_power_set_customer_mode(2)，进入 CUSTOMER_SINGLE_LONG_CHARGING_MODE。手动单参数设置模式 2 也调用同一 setter；没有证据支持“自动计满才走另一个秘密直供电入口”。自动路径还调用电源状态变化通知。
4. customer_mode 的写入口确实支持“模式 + 分钟数”的调试配置，能改动内核实际等待周期，并非仅改显示。但没有执行写入或验证最终供电效果。
5. 模式 2 是长充状态机，不应等同于任何电量下立即停止充电、切断电池或保证物理旁路供电。

## 调查范围与证据身份

- 调查目录日期标识：20261029。
- 调查设备：QTI ARM32 Linux 5.4.226；内核编译信息 #1 PREEMPT Thu Apr 10 07:14:03 UTC 2025。
- 调查时 boot 分区只读导出：boot-current.img（仅保留于本地工作目录，未纳入此次提交）。
- 导出文件 SHA256 与设备 /dev/mtd19 的只读校验结果一致：
  1ca2deef24e0c974e8cfe0011da5407ce4d79363fc56de6783553c3750c0edad
- 对当前镜像解压并恢复 kallsyms；前序校验 102672 个核心符号的名称、类型和顺序与实时脱敏 kallsyms 对应，零差异。没有用旧 work/vmlinux.bin 替代当前镜像。
- 下述地址为离线当前镜像的符号地址，不是获得写内核地址的授权，也不是已经验证可直接访问的运行时地址。
- 原始设备时间输出保存在快照中；没有同步或修改设备时钟。

## 一、原生计时逻辑

入口：zte_battery_thermal_usr_work，0xb091099c。

简化伪代码（省略日志、调度细节）：

    if algorithm_type not in {5, 6}: return
    if customer_mode in {2, 3}: return
    if charger_connected != 1:
        battery_full_flag = false
        period_ts = 0
        return
    if real_capacity_mbb != 100 and not battery_full_flag:
        battery_full_flag = false
        period_ts = 0
        return
    battery_full_flag = true
    if period_ts == 0: period_ts = jiffies
    if elapsed_jiffies >= msecs_to_jiffies(single_lcm_period_ms):
        zte_power_set_customer_mode(2)
        zte_power_supply_changed(...)
    else:
        schedule_remaining_wait(...)

关键字段及验证：

| 内容 | 位置 / 值 |
| --- | --- |
| charger_connected | 电池结构 +0x49c |
| REAL_CAPACITY_MBB | 电池结构 +0x4ac |
| 算法类型 | +0x508 |
| customer_mode | +0x510 |
| 周期（毫秒） | +0x2c0 |
| period_ts | 静态变量 0xb175bee8 |
| battery_full_flag | 静态变量 0xb175beec |
| 默认周期 | 0x036ee800 = 57600000 ms = 960 min |

电量字段不是猜测：zte_battery_get_property 的跳转表将属性编号 99 映射到 0xb0911bf4，读取 +0x4ac；power_supply_attrs 表（基址 0xb1671304，条目宽 60 字节）的编号 99 名称是 REAL_CAPACITY_MBB。

含义：
- 这里的“满电”是中兴驱动 real_capacity_mbb == 100 的判定，不等同于界面数值或对电池实际化学容量的测量保证。
- 首次判满后标志被锁存；之后电量稍降，不会仅因此重新从零计时。
- 连接变化监测会重置模式并调度相关工作；用户计时工作在未连接时清除本次计时状态。不能据此声称极短断连必定被采样捕获。
- 使用 jiffies，不读取界面累计值或日历时钟；修改网页显示、统计文件或系统日期不是这条计时路径的输入。
- 当前算法类型的运行值未独立读出；不能仅凭阈值存在保证所有固件配置都启用了这条工作路径。

## 二、隐藏的周期配置入口

路径：/sys/class/power_supply/battery_zte/customer_mode。
入口：zte_battery_store_customer_mode，0xb090d0bc。
格式解析：sscanf(buffer, "%d %d %d", ...)。第三参数在已分析控制流中未见用于此周期。

### 单参数模式设置

- 解析到单参数 1..3，或者第二参数为 0 时，走 zte_power_set_customer_mode(mode)。
- 因而参数文本“2 0”并不代表等待 0 分钟。
- setter 对同模式提前返回，对降低优先级的请求不按普通赋值执行；不能假设写 1 就一定能撤销已进入的模式 2。

### 双参数周期设置（仅静态分析，未执行）

首参数为 2、第二参数 N >= 1 时：

    customer_mode_dbg = 1
    clear_lcm_history_memory()
    customer_mode = 1
    single_lcm_period_ms = N * 60000
    reschedule_thermal_work()
    reschedule_lcm_record_work()

- 参数文本“2 1”含义是把原生等待周期设为 1 分钟，而非将已供电时间写为 960 分钟。
- 参数文本“2 960”是设置周期为 960 分钟，不是设置已等待 960 分钟。
- 该入口不直接重置 period_ts 和 battery_full_flag；若已有满电计时，缩短阈值可能按已有起点立即达到条件，不能承诺“从写入时起刚好等 1 分钟”。
- thermal_work 的相关路径会重新调度用户计时工作；是否在当前运行状态立即重算，仍需实机受控验证。
- 它还设置调试标志、清除历史记录内存并重置模式，不是无副作用的只读时间修改。
- 尚未验证持久性、完整恢复流程、各电量和温度下的最终行为，因此本轮不执行。

默认初始化：zte_battery_thermal_algorithm_init，0xb090bdf8；写入默认 960 分钟、模式 1、debug 0，并将历史 LCM 用户禁用标志设为 1。

## 三、lcm_record 不是这个满电计时器

调查时 lcm_record 返回 lcm_usr_disabled，cur_runtime/cur_charger_time 及记录均为零。

- zte_battery_lcm_work（0xb09116a0）会检查历史记录用户禁用标志 +0x51c。
- zte_battery_thermal_usr_work 不以这个标志为入口条件。
- zte_battery_store_lcm_record（0xb090cfd4）未提供直接赋值已供电分钟数的分支；其中值 1 的条件分支涉及写记录文件。
- 因此“记录禁用/为零”不能推导出单次满电 960 分钟计时也关闭；也不能把伪造 /logfs/battery_lcm_record 当成已验证的触发方案。
- scene_record 中 charger_LongTimeUse_num=6 只能作为统计字段，不应宣称已证实发生六次物理直供电。

## 四、进入模式 2 后是不是直供电

已经确认：

- zte_power_set_customer_mode（0xb090bef0）更新实际驱动状态，涉及重置热控状态和模式事件，不是 UI 变量。
- battery_info_get_thermal_status（0xb0912b78）在模式 2/3 选择 lcm_thermal_status，模式 1 选择普通表。
- 长充表包含 charging、done、recharge、suspend、discharging prepare/start/loop/done/recharge 等阶段；表存在不能替代“实机走到了哪一阶段”的验证。
- 热控动作通过 zte_power_bat_changed_work 和 zte_charger_set_property 等路径传递；后者会应用充电电流、电压、输入电流、电压和终止电流配置。
- smblib_set_usb_suspend（0xb07a87a8）和 smblib_chg_disable_vote_callback（0xb07b4b6c）还有中兴特定分支：thermal_id > 10 或 customer_mode >= 2 时，不执行各自普通寄存器更新路径。故普通 USB suspend / 禁止充电投票在此模式下也不宜机械类比。
- zte_smblib_charger_set_status（0xb07a66d8）另有直接更新充电开关寄存器的路径。

尚未证明：

- 模式 2 是否在当前电量、温度和已配置策略下立即停充。
- 最终是否 USB 供负载且电池净电流接近零，还是先放电、后补充充电等策略。
- 电池是否电气隔离，以及是否存在持续物理旁路；仅读模式、状态字符串或接近零的瞬时电流不足以证明。

因此，先前“模式 2 就一定直供电”不成立；反过来，“手动模式 2 无效而计满必走另一套神秘入口”也没有当前代码证据。

## 五、结束时只读复核

本地 final-readonly-check.txt（关键结果已收录于 evidence.txt）：

- 调查前后 boot_id 一致，期间未重启。
- customer mode = 1。
- single_lcm_period = 960 minutes。
- customer_mode_dbg = 0。
- real_capacity_mbb = 100，USB online = 1。
- lcm_record 仍为禁用、零记录。
- 当前 boot SHA256 与导出文件一致。

本轮未写设备 sysfs/寄存器，未改时钟、未重启、未刷机；仅保存本地调查产物，没有修改业务程序实现。

## 对原始目标的判断

“USB 一插上就让驱动认为已经供电 960 分钟”不是现有发现的参数语义。

现在已定位的是两层真实控制：

1. 原生满电后等待周期可以由驱动调试入口配置；
2. 模式 2 可以进入同一原生长充状态体系，但仍需分析/验证之后的电池管理阶段。

若继续，最小受控验证应先明确恢复方案，在记录温度、电量、USB 输入和电池电流的条件下验证短周期是否触发原生模式迁移。不要以改模式数值或界面提示作为“物理直供电成功”的验收条件。

## 已提交的最小证据集

- [evidence.txt](evidence.txt)：关键函数的原始反汇编摘录及结束时只读快照。保留函数地址和指令；摘录仅裁剪函数范围并清除行尾空白，没有修改指令。
- [fields.json](fields.json)：固件身份、REAL_CAPACITY_MBB 属性映射及计时字段。

反汇编辅助注释由本地脚本生成，分支和立即数应以指令为准；内联跳转表可能被反汇编器显示为指令，不能据此猜测控制流。字段映射另经原始二进制校验。

## 本地完整调查产物（本次未提交）

工作目录：

`work/lcm-investigation-20261029/`

- 原始快照：device-snapshot.txt、capacity-check.txt、final-readonly-check.txt。
- 完整反汇编：lcm-disassembly.txt、control-disassembly.txt、property-disassembly.txt、thermal-table-disassembly.txt、power-action-disassembly.txt、smb5-control-disassembly.txt。
- 镜像及符号：boot-current.img、kernel-current.bin、kernel-current.kallsyms。
- 临时工具：disassemble.py、tooldeps/。

固件镜像、完整运行日志、设备标识、第三方依赖和本地 Python 运行时不纳入此次提交。重新验证二进制字段时，需要相同 SHA256 的镜像；仅凭这些文字证据不能完成硬件供电行为验收。
