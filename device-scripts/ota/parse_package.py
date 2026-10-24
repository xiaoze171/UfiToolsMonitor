#!/usr/bin/env python3
"""ZTE MU5120 OTA 升级包解析器（容器格式已破解）

格式：magic 55AA5588 + 条目数(u32) + N×[name32 + chunk_size(u32) + chunk_start(u32)]
每个 .mld 组件 = 分区差分补丁（ZDF01.07/ZFD01.02 容器，内含 NORMDIFF + IMGDIFF2 段）
或明文脚本/ELF（preprocessing 等直接是 #!/bin/sh）
包尾 32 字符 ASCII = 整包（除尾部）的 MD5

用法：python parse_package.py delta.package [-x 解包目录]
"""
import struct, sys, os, hashlib

def main():
    path = sys.argv[1]
    extract = '-x' in sys.argv
    outdir = sys.argv[sys.argv.index('-x')+1] if extract else None
    d = open(path, 'rb').read()
    magic, cnt = struct.unpack_from('<II', d, 0)
    assert magic == 0x55AA5588, "非 ZTE OTA 容器"
    print("条目数: %d, 大小: %d, MD5: %s" % (cnt, len(d), hashlib.md5(d[:-32]).hexdigest()))
    tail = d[-32:].decode('ascii', 'replace')
    print("尾部校验: %s  %s" % (tail, "✓ 一致" if tail == hashlib.md5(d[:-32]).hexdigest() else "✗ 不一致"))
    ents = []
    for i in range(cnt):
        off = 0x10 + i*40
        name = d[off:off+32].split(b'\0')[0].decode('ascii', 'replace')
        size, start = struct.unpack_from('<II', d, off+32)
        ents.append((name, start, size))
        print("%-22s start=%-10d size=%d" % (name, start, size))
        if extract:
            os.makedirs(outdir, exist_ok=True)
            open(os.path.join(outdir, name), 'wb').write(d[start:start+size])

if __name__ == '__main__':
    main()
