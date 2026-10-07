# -*- coding: utf-8 -*-
"""從 CC0 示範照片（raw.pixls.us）裁切／調色出一組示意用的相簿照片，外加一張假的「螢幕截圖」。"""
import pathlib
from PIL import Image, ImageEnhance, ImageOps, ImageDraw, ImageFilter

SRC = Image.open(r"E:/test_think/demo/DSC00846.JPG").convert("RGB")
OUT = pathlib.Path(__file__).parent / "img"
OUT.mkdir(exist_ok=True)
W, H = SRC.size  # 1616 x 1080


def crop(box, size, *, warm=0.0, sat=1.0, bright=1.0, contrast=1.0, bw=False, mirror=False):
    l, t, r, b = box
    im = SRC.crop((int(l * W), int(t * H), int(r * W), int(b * H)))
    im = ImageOps.fit(im, size, Image.LANCZOS)
    if mirror:
        im = ImageOps.mirror(im)
    if bw:
        im = ImageOps.grayscale(im).convert("RGB")
    im = ImageEnhance.Color(im).enhance(sat)
    im = ImageEnhance.Brightness(im).enhance(bright)
    im = ImageEnhance.Contrast(im).enhance(contrast)
    if warm:
        r_, g_, b_ = im.split()
        r_ = r_.point(lambda v: min(255, int(v * (1 + warm))))
        b_ = b_.point(lambda v: int(v * (1 - warm * 0.8)))
        im = Image.merge("RGB", (r_, g_, b_))
    return im


# 卡片（直式 3:4）
crop((0.18, 0.0, 0.82, 1.0), (900, 1200)).save(OUT / "card_main.jpg", quality=90)
crop((0.55, 0.0, 1.0, 0.62), (900, 1200), warm=0.18, sat=1.15).save(OUT / "card_next.jpg", quality=90)

# 月份封面與垃圾桶格子（正方形）
squares = {
    "sq1": dict(box=(0.30, 0.10, 0.65, 0.55)),
    "sq2": dict(box=(0.0, 0.0, 0.40, 0.55), warm=0.15),
    "sq3": dict(box=(0.25, 0.50, 0.75, 1.0), sat=1.2),
    "sq4": dict(box=(0.60, 0.05, 1.0, 0.60), bw=True, contrast=1.2),
    "sq5": dict(box=(0.0, 0.45, 0.45, 1.0), bright=0.85),
    "sq6": dict(box=(0.45, 0.30, 0.90, 0.85), warm=0.3, sat=1.3),
    "sq7": dict(box=(0.10, 0.20, 0.55, 0.75), mirror=True),
    "sq8": dict(box=(0.50, 0.0, 0.95, 0.45), bright=1.15, sat=0.8),
    "sq9": dict(box=(0.20, 0.35, 0.60, 0.80), warm=-0.15, sat=0.9),
    "sq10": dict(box=(0.65, 0.40, 1.0, 1.0), warm=0.1),
    "sq11": dict(box=(0.05, 0.05, 0.50, 0.50), bw=True),
    "sq12": dict(box=(0.35, 0.55, 0.80, 1.0), bright=1.1, contrast=1.1),
}
for name, opts in squares.items():
    crop(size=(360, 360), **opts).save(OUT / f"{name}.jpg", quality=88)

# 假的螢幕截圖（灰色介面方塊），放在垃圾桶格子裡
shot = Image.new("RGB", (360, 360), (242, 242, 247))
d = ImageDraw.Draw(shot)
d.rectangle((0, 0, 360, 46), fill=(255, 255, 255))
for i, y in enumerate(range(70, 340, 54)):
    d.rounded_rectangle((18, y, 342, y + 40), radius=10, fill=(255, 255, 255))
    d.ellipse((30, y + 8, 54, y + 32), fill=[(52, 199, 89), (0, 122, 255), (255, 149, 0), (175, 82, 222), (255, 59, 48)][i % 5])
    d.rounded_rectangle((66, y + 12, 66 + 120 + (i * 37) % 120, y + 28), radius=6, fill=(209, 209, 214))
shot.save(OUT / "shot.jpg", quality=88)

# 全螢幕預覽用的原圖（橫式）
crop((0.0, 0.0, 1.0, 1.0), (1616, 1080)).save(OUT / "full.jpg", quality=90)
print("images:", sorted(p.name for p in OUT.iterdir()))
