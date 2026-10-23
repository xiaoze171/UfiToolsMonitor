#!/usr/bin/env python3
"""生成 MU5120 boot 镜像补丁：把电池档案的 batt-id-kohm 由 20 改成 0。

背景：设备 batt_id 通道实测 0mV（ID 引脚读不到有效电阻），不匹配 COSMX(20kΩ)
与 FENGHUA(47kΩ) 任一档案 → QG 判定 Unknown Battery → 拿不到 FCC → SOC 锁死 50。
把 COSMX 档案的期望 ID 改成 0 后，0Ω 读数即可匹配，档案中的 FCC/OCV 表随之生效。

用法：
    python patch-dtb.py 备份/mtd19_boot.img work/boot_patched.img

注意：boot 分区被内核模块 zte_flash_protect 写保护，root 下写入会被静默丢弃
（fota 分区可写、boot 不可写），因此生成的镜像需要借助 recovery / DL 模式 /
EDL 等外部通道刷入，用户态 dd 无效。
"""

import re
import struct
import sys


def find_dtbs(buf):
    """扫描 QCDT 容器中的所有有效 FDT。"""
    out = []
    for m in re.finditer(b"\xd0\x0d\xfe\xed", buf):
        o = m.start()
        if o + 40 > len(buf):
            continue
        f = struct.unpack(">10I", buf[o:o + 40])
        magic, tot, off_struct, off_strings, off_rsvmap, ver = f[:6]
        size_strings, size_struct = f[8], f[9]
        if ver in (16, 17) and o + tot <= len(buf) and size_struct < tot:
            out.append((o, tot, off_struct, off_strings, size_strings, size_struct))
    return out


def main(src, dst):
    img = bytearray(open(src, "rb").read())
    orig = bytes(img)
    changed = []

    for o, tot, off_struct, off_strings, size_strings, size_struct in find_dtbs(orig):
        blob = orig[o:o + tot]
        if b"6441244_ZTE_COSMX" not in blob:      # 只处理 COSMX 档案所在的 DTB
            continue

        # 在字符串块中定位属性名，再在结构块中定位对应属性（len=4 的 u32）
        nameoff = blob[off_strings:off_strings + size_strings].find(b"qcom,batt-id-kohm\x00")
        if nameoff < 0:
            print("DTB@0x%x 未找到 qcom,batt-id-kohm" % o)
            continue

        pat = struct.pack(">III", 4, nameoff, 20)   # 长度 4、属性名偏移、值 20
        base = o + off_struct
        block = orig[base:base + size_struct]
        hits = [m.start() for m in re.finditer(re.escape(pat), block)]
        if len(hits) != 1:
            print("DTB@0x%x 候选数异常 %d，跳过" % (o, len(hits)))
            continue

        valpos = base + hits[0] + 8                  # 跳过 len + nameoff
        img[valpos:valpos + 4] = struct.pack(">I", 0)
        changed.append(valpos)
        print("DTB@0x%x: 0x%x  20 -> 0" % (o, valpos))

    if not changed:
        print("未做任何修改（镜像可能已是补丁版或不含目标档案）")
        return 1

    open(dst, "wb").write(bytes(img))
    diff = sum(1 for a, b in zip(orig, bytes(img)) if a != b)
    print("输出 %s，改动字节数 %d" % (dst, diff))
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2]))
