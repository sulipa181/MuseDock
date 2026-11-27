#!/usr/bin/env python3
"""產生 MuseDock 的 App 圖示（1024×1024 PNG + .icns）

設計：深色 squircle 底 + 三張斜疊卡片（呼應「疊號」），最上層卡片帶對話氣泡。
輸出：~/MuseDock/AppIcon.png 與 ~/MuseDock/AppIcon.icns
"""
import math
import os
import subprocess

from PIL import Image, ImageDraw, ImageFilter

S = 4096            # 超取樣畫布
K = S / 1024        # 縮放係數
OUT = os.path.expanduser("~/MuseDock")


def rgba(hexstr, a=255):
    hexstr = hexstr.lstrip("#")
    return tuple(int(hexstr[i:i + 2], 16) for i in (0, 2, 4)) + (a,)


def vertical_gradient(size, top, bottom):
    w, h = size
    grad = Image.new("RGB", (1, h))
    d = ImageDraw.Draw(grad)
    for y in range(h):
        t = y / max(1, h - 1)
        c = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        d.point((0, y), fill=c)
    return grad.resize((w, h), Image.BILINEAR)


def squircle_mask(size, radius):
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m


def card(size, radius, fill_image=None, fill_color=None, border=None):
    """回傳一張帶圓角的卡片 RGBA"""
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    if fill_image is not None:
        layer.paste(fill_image, (0, 0))
    else:
        ImageDraw.Draw(layer).rounded_rectangle(
            [0, 0, size - 1, size - 1], radius=radius, fill=fill_color)
    mask = squircle_mask(size, radius)
    layer.putalpha(mask)
    if border:
        ImageDraw.Draw(layer).rounded_rectangle(
            [1, 1, size - 2, size - 2], radius=radius, outline=border,
            width=max(2, round(size * 0.006)))
    return layer


def drop_shadow(shape, blur, opacity, offset=(0, 0)):
    blur = max(1, int(round(blur)))
    offset = (int(offset[0]), int(offset[1]))
    pad = blur * 3
    w, h = shape.size
    canvas = Image.new("RGBA", (w + pad * 2, h + pad * 2), (0, 0, 0, 0))
    alpha = shape.split()[3].point(lambda a: min(255, int(a * opacity)))
    shadow = Image.new("RGBA", shape.size, (0, 0, 0, 255))
    shadow.putalpha(alpha)
    canvas.paste(shadow, (pad + offset[0], pad + offset[1]), shadow)
    return canvas.filter(ImageFilter.GaussianBlur(blur)), pad


canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# ── 底板 824×824（Apple 圖示留邊模板）──
plate = round(824 * K)
plate_r = round(185 * K)
px = py = (S - plate) // 2

bg = vertical_gradient((plate, plate), (0x24, 0x2A, 0x52), (0x08, 0x0A, 0x14)).convert("RGBA")

# 左上角柔光
glow = Image.new("RGBA", (plate, plate), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
gd.ellipse([-plate * 0.35, -plate * 0.45, plate * 0.85, plate * 0.55],
           fill=(0x5B, 0x7C, 0xFF, 54))
glow = glow.filter(ImageFilter.GaussianBlur(plate * 0.12))
bg.alpha_composite(glow)

plate_img = card(plate, plate_r, fill_image=bg, border=(255, 255, 255, 26))

# 底板陰影
shadow, pad = drop_shadow(plate_img, blur=26 * K, opacity=0.42, offset=(0, int(14 * K)))
canvas.alpha_composite(shadow, (px - pad, py - pad))
canvas.alpha_composite(plate_img, (px, py))

# ── 三張斜疊卡片 ──
cw = round(468 * K)
cr = round(112 * K)

front_grad = vertical_gradient((cw, cw), (0x5C, 0x9C, 0xFF), (0x6D, 0x4B, 0xF0))


def make_stack_card(kind):
    if kind == "back":
        return card(cw, cr, fill_color=rgba("#3B3070"), border=(255, 255, 255, 46))
    if kind == "mid":
        return card(cw, cr, fill_color=rgba("#5A48BC"), border=(255, 255, 255, 40))
    return card(cw, cr, fill_image=front_grad.convert("RGBA"), border=(255, 255, 255, 30))


# 由後到前：角度、位移（以 1024 座標計）、透明度、陰影強度
layout = [
    ("back", -15, -54, -46, 0.72, 0.50),
    ("mid", -7.5, -27, -23, 0.90, 0.40),
    ("front", 0, 0, 0, 1.0, 0.34),
]

rotated_layers = []
for kind, angle, dx, dy, alpha, opacity in layout:
    c = make_stack_card(kind)
    if alpha < 1.0:
        c.putalpha(c.split()[3].point(lambda v: int(v * alpha)))
    rotated_layers.append((c.rotate(angle, resample=Image.BICUBIC, expand=True),
                           dx * K, dy * K, opacity))

# 三張的聯合邊界 → 整體置中
lefts, tops, rights, bottoms = [], [], [], []
for img, dx, dy, _ in rotated_layers:
    lefts.append(dx - img.width / 2)
    rights.append(dx + img.width / 2)
    tops.append(dy - img.height / 2)
    bottoms.append(dy + img.height / 2)
gx = (min(lefts) + max(rights)) / 2
gy = (min(tops) + max(bottoms)) / 2
cx, cy = S / 2 - gx, S / 2 - gy

for img, dx, dy, opacity in rotated_layers:
    ox = int(cx + dx - img.width / 2)
    oy = int(cy + dy - img.height / 2)
    sh, sp = drop_shadow(img, blur=18 * K, opacity=opacity, offset=(0, int(10 * K)))
    canvas.alpha_composite(sh, (ox - sp, oy - sp))
    canvas.alpha_composite(img, (ox, oy))

# ── 前景卡片上的對話氣泡 ──
bubble = Image.new("RGBA", (S, S), (0, 0, 0, 0))
bd = ImageDraw.Draw(bubble)
bw, bh = 224 * K, 154 * K
bx = cx - bw / 2
by = cy - bh / 2 - 5 * K
bd.rounded_rectangle([bx, by, bx + bw, by + bh], radius=48 * K, fill=(255, 255, 255, 255))
# 尾巴
tail = [(bx + bw * 0.28, by + bh - 4 * K),
        (bx + bw * 0.28, by + bh + 50 * K),
        (bx + bw * 0.56, by + bh - 4 * K)]
bd.polygon(tail, fill=(255, 255, 255, 255))
# 三個點
for i in (-1, 0, 1):
    r = 15.5 * K
    ddx = bx + bw / 2 + i * 53 * K
    ddy = by + bh / 2
    bd.ellipse([ddx - r, ddy - r, ddx + r, ddy + r], fill=(0x3B, 0x36, 0x8F, 255))
canvas.alpha_composite(bubble)

# ── 輸出 ──
icon = canvas.resize((1024, 1024), Image.LANCZOS)
png_path = os.path.join(OUT, "AppIcon.png")
icon.save(png_path)
print("wrote", png_path)

iconset = os.path.join(OUT, "AppIcon.iconset")
subprocess.run(["rm", "-rf", iconset], check=True)
os.makedirs(iconset, exist_ok=True)
for base in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        size = base * scale
        name = f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png"
        icon.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, name))
icon.save(os.path.join(iconset, "icon_512x512@2x.png"))
subprocess.run(["iconutil", "-c", "icns", iconset, "-o",
                os.path.join(OUT, "AppIcon.icns")], check=True)
subprocess.run(["rm", "-rf", iconset], check=True)
print("wrote", os.path.join(OUT, "AppIcon.icns"))
