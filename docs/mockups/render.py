# -*- coding: utf-8 -*-
"""重新產生 README 用的示意截圖。

1. python make_images.py   從 CC0 範例照片做出 img/ 裡的示意照片
2. python render.py        用 Edge 無頭模式渲染 screens.html，輸出到 ../ （docs/）

需要 Windows 上的 Microsoft Edge、Pillow，以及能連上 cdn.jsdelivr.net（圖示字型）。
畫面文字與版面要跟著 PhotoSweep/Views 的程式碼同步修改。
"""
import pathlib, subprocess, tempfile
from PIL import Image, ImageDraw

HERE = pathlib.Path(__file__).resolve().parent
DOCS = HERE.parent
EDGE = r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
SCREENS = ["permission", "home", "swipe", "trash"]
RAW = HERE / "out"
RAW.mkdir(exist_ok=True)

with tempfile.TemporaryDirectory() as profile:  # 沒有獨立設定檔時 Edge 不會輸出截圖
    for lang in ["zh", "en"]:
        for s in SCREENS:
            subprocess.run([
                EDGE, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                f"--user-data-dir={profile}", "--force-device-scale-factor=3",
                "--window-size=393,852", "--virtual-time-budget=4000",
                f"--screenshot={RAW / f'{s}-{lang}.png'}",
                f"{(HERE / 'screens.html').as_uri()}?screen={s}&lang={lang}",
            ], check=True, capture_output=True, timeout=90)


def rounded(im, r):
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, im.size[0] - 1, im.size[1] - 1), radius=r, fill=255)
    out = Image.new("RGBA", im.size, (0, 0, 0, 0))
    out.paste(im, (0, 0), mask)
    return out


def framed(im, w):
    """細灰框模擬手機外框，黑底畫面在 GitHub 深色主題也看得出邊界"""
    h = round(im.size[1] * w / im.size[0])
    im = im.convert("RGB").resize((w, h), Image.LANCZOS)
    b = 6
    frame = rounded(Image.new("RGB", (w + 2 * b, h + 2 * b), (58, 58, 60)), int(w * 0.13) + b)
    frame.alpha_composite(rounded(im, int(w * 0.13)), (b, b))
    return frame


for lang in ["zh", "en"]:
    shots = [framed(Image.open(RAW / f"{n}-{lang}.png"), 360) for n in SCREENS]
    gap = 36
    sheet = Image.new("RGBA", (sum(s.size[0] for s in shots) + gap * 3, shots[0].size[1]), (0, 0, 0, 0))
    x = 0
    for s in shots:
        sheet.alpha_composite(s, (x, 0))
        x += s.size[0] + gap
    sheet.save(DOCS / f"screens-{lang}.png", optimize=True)
    for n in SCREENS:
        framed(Image.open(RAW / f"{n}-{lang}.png"), 540).save(DOCS / f"{n}-{lang}.png", optimize=True)
print("done:", sorted(p.name for p in DOCS.glob("*.png")))
