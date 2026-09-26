#!/usr/bin/env python3
"""生成应用图标（默认 Flutter 图标换成自有图标）。

只用标准库：没有 PIL / ImageMagick 的构建机上也能重新生成，保证图标是可复现的
产物而不是某个人的临时文件。

产物（相对 android/app/src/main/res/）：
  mipmap-<density>/ic_launcher.png             传统方形图标（API 24-25 与忽略
                                               自适应图标的启动器用）
  mipmap-<density>/ic_launcher_foreground.png  自适应图标前景（透明底，白色书签，
                                               API 26+ 由 mipmap-anydpi-v26/
                                               ic_launcher.xml 组合背景使用）

图案：品牌青绿渐变圆角方块 + 白色书签（首页就是书签墙）。4 倍超采样后缩小，
所以边缘是抗锯齿的。

用法：python3 tool/make_app_icon.py
"""

import os
import struct
import zlib

# 与 lib/ui/theme.dart 的 seedColor 同色系，深一点做渐变。
TOP = (0x1A, 0xA3, 0xB0)
BOTTOM = (0x0A, 0x58, 0x60)
WHITE = (0xFF, 0xFF, 0xFF)

LEGACY_SIZES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
ADAPTIVE_SIZES = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}

RES = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "android", "app", "src", "main", "res",
)

SUPERSAMPLE = 4

# 传统图标：圆角方块几乎占满画布；自适应前景：同样形状按比例缩小，留在安全区内。
CORNER_RADIUS = 0.235
BOOKMARK = dict(x0=0.335, x1=0.665, y0=0.215, y1=0.785, notch=0.155)
FOREGROUND_SCALE = 0.78


def _in_rounded_square(u, v, radius):
    if u < 0 or u > 1 or v < 0 or v > 1:
        return False
    if u < radius and v < radius:
        return (u - radius) ** 2 + (v - radius) ** 2 <= radius ** 2
    if u > 1 - radius and v < radius:
        return (u - (1 - radius)) ** 2 + (v - radius) ** 2 <= radius ** 2
    if u < radius and v > 1 - radius:
        return (u - radius) ** 2 + (v - (1 - radius)) ** 2 <= radius ** 2
    if u > 1 - radius and v > 1 - radius:
        return (u - (1 - radius)) ** 2 + (v - (1 - radius)) ** 2 <= radius ** 2
    return True


def _in_bookmark(u, v, shape):
    x0, x1 = shape["x0"], shape["x1"]
    y0, y1 = shape["y0"], shape["y1"]
    if not (x0 <= u <= x1 and y0 <= v <= y1):
        return False
    # 底部三角缺口：缺口内挖空，形成书签的 V 形。
    depth = shape["notch"]
    if v > y1 - depth:
        half = (x1 - x0) / 2
        if abs(u - 0.5) < half * (y1 - v) / depth:
            return False
    return True


def _scaled(shape, factor):
    return {key: 0.5 + (value - 0.5) * factor for key, value in shape.items()}


def _subpixel(u, v, kind):
    """一个子采样点的颜色，返回**预乘** RGBA（0-255）。"""
    if kind == "foreground":
        if _in_bookmark(u, v, _scaled(BOOKMARK, FOREGROUND_SCALE)):
            return WHITE + (255,)
        return (0, 0, 0, 0)

    if not _in_rounded_square(u, v, CORNER_RADIUS):
        return (0, 0, 0, 0)
    if _in_bookmark(u, v, BOOKMARK):
        return WHITE + (255,)
    t = min(max(v, 0.0), 1.0)
    return tuple(round(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3)) + (255,)


def _render(size, kind):
    n = size * SUPERSAMPLE
    rows = []
    for y in range(size):
        row = []
        for x in range(size):
            r = g = b = a = 0
            for sy in range(SUPERSAMPLE):
                for sx in range(SUPERSAMPLE):
                    u = (x * SUPERSAMPLE + sx + 0.5) / n
                    v = (y * SUPERSAMPLE + sy + 0.5) / n
                    pr, pg, pb, pa = _subpixel(u, v, kind)
                    r += pr
                    g += pg
                    b += pb
                    a += pa
            total = SUPERSAMPLE * SUPERSAMPLE
            a //= total
            if a == 0:
                row.append((0, 0, 0, 0))
            else:
                # 预乘平均后还原成直通 alpha，避免透明边缘出现黑边。
                row.append((min(255, r * 255 // (total * a)),
                            min(255, g * 255 // (total * a)),
                            min(255, b * 255 // (total * a)), a))
        rows.append(row)
    return rows


def _chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def _write_png(path, rows):
    height = len(rows)
    width = len(rows[0])
    raw = b"".join(
        b"\x00" + bytes(value for pixel in row for value in pixel) for row in rows
    )
    png = (b"\x89PNG\r\n\x1a\n"
           + _chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
           + _chunk(b"IDAT", zlib.compress(raw, 9))
           + _chunk(b"IEND", b""))
    with open(path, "wb") as handle:
        handle.write(png)


def main():
    written = []
    for density, size in LEGACY_SIZES.items():
        directory = os.path.join(RES, "mipmap-" + density)
        os.makedirs(directory, exist_ok=True)
        path = os.path.join(directory, "ic_launcher.png")
        _write_png(path, _render(size, "legacy"))
        written.append(path)

        fg_path = os.path.join(directory, "ic_launcher_foreground.png")
        _write_png(fg_path, _render(ADAPTIVE_SIZES[density], "foreground"))
        written.append(fg_path)

    for path in written:
        print(f"{os.path.getsize(path):>7}  {os.path.relpath(path, os.path.dirname(RES))}")


if __name__ == "__main__":
    main()
