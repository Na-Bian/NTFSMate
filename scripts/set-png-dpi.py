#!/usr/bin/env python3
# set-png-dpi.py — 向 PNG 写入 pHYs 块 (物理分辨率), 无外部依赖
# 用法: python3 scripts/set-png-dpi.py <png> <dpi>
# Finder 按 pt 渲染 DMG 背景图: 无 DPI 的 PNG 按 72dpi (1px=1pt) 显示会放大一倍;
# @2x 产物 (1280×800 px) 必须声明 144dpi 才等于 640×400 pt。
import struct, sys, zlib

def inject_phys(path, dpi):
    ppm = round(dpi / 0.0254)  # pixels per meter
    data = struct.pack(">IIB", ppm, ppm, 1)  # x_ppm, y_ppm, unit=meter
    chunk_type = b"pHYs"
    crc = zlib.crc32(chunk_type + data) & 0xFFFFFFFF
    chunk = struct.pack(">I", len(data)) + chunk_type + data + struct.pack(">I", crc)

    with open(path, "rb") as f:
        raw = f.read()
    assert raw[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    assert raw[12:16] == b"IHDR", "first chunk is not IHDR"
    if b"pHYs" in raw:
        return False  # 已有 pHYs
    ihdr_len = struct.unpack(">I", raw[8:12])[0]
    # 签名(8) + 长度(4) + 类型(4) + IHDR数据(ihdr_len) + CRC(4) 之后即下一块起点
    insert_at = 8 + 8 + ihdr_len + 4
    out = raw[:insert_at] + chunk + raw[insert_at:]
    with open(path, "wb") as f:
        f.write(out)
    return True

if __name__ == "__main__":
    changed = inject_phys(sys.argv[1], float(sys.argv[2]))
    print(("pHYs written to " if changed else "pHYs already present in ") + sys.argv[1])
