# MU5120 全量备份清单（2026-10-23 15:19 更新）

## 一、文件级备份（所有可读文件）
| 文件 | 大小 | 内容 |
|---|---|---|
| rootfs-files.tar.gz | 141.6MB | 根文件系统全部文件（/etc、/usr、systemd 单元） |
| cache-files.tar.gz | 2.9MB | /cache（zwrt-datad 配置、电量计脚本、OTA 状态） |
| persist-etc_rw-files.tar.gz | 409KB | /persist（IMEI/校准）+ /etc_rw |
| ztedata-firmware-files.tar.gz | 69MB | /usr/zte_web + /firmware |

## 二、裸分区位级镜像（22 个，用于救砖）
| 分区 | 大小 | 用途 |
|---|---|---|
| mtd00 sbl / mtd01 mibib | 2.5MB×2 | 一级引导 |
| mtd03 efsbak | 6MB | EFS 备份区（IMEI/校准） |
| mtd04-21 | 1~2MB each | ztefile/tz/ddr/apdp/xbl_config/xbl_ramdump/multi_image/aop/qhee/abl/uefi/toolsfv/loader_sti/**boot(19MB)**/scrub/logfs |
| mtd22 modem | 91MB | 基带固件 |
| mtd23 misc / mtd24 devinfo / mtd26 fota | 1.5~1.8MB | 启动参数/设备信息/FOTA |
| mtd25 recovery / mtd27 recoveryfs | 19MB / 35MB | **恢复系统**（可进 recovery 重刷） |
| mtd28-30 sec/ipa_fw/usb_qti | 1MB each | 安全/固件 |

## 三、未备份（有风险，不建议在系统内读取）
- mtd02 efs2（modem 独占，dd 裸读曾触发内核崩溃重启）
- mtd31 zterw / mtd32 system（UBI 挂载中，裸读可能不一致；文件级已覆盖其内容）

## 四、救砖能力评估
1. **可自作恢复介质**：recovery/recoveryfs + 全部引导链镜像在手，理论上可用 fastboot/EDL 按分区回写
2. **缺失环节**：firehose programmer（EDL 写入必需）与官方全量包 —— 需从社区或售后渠道获取
3. **最高风险操作**：写 mtd19(boot)/mtd00-18（引导链），一旦写坏且无 programmer 则需返厂
4. **低风险**：仅改 UBI 卷内文件（system/zterw），可通过 recovery + 全量包恢复

校验：SHA256SUMS 为设备端生成，4 个 tar 与本地逐一比对一致。
