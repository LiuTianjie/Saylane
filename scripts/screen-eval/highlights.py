#!/usr/bin/env python3
"""Four-way strips for a few samples: source, shipping pipeline, V2 prototype, the publisher's own localisation.

    highlights.py <pages-dir> <out-dir> <highlights-dir>     (needs Pillow)
"""
import os
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

FONTS = ["/System/Library/Fonts/PingFang.ttc", "/System/Library/Fonts/Hiragino Sans GB.ttc",
         "/System/Library/Fonts/STHeiti Medium.ttc", "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"]


def strip(cells, crop, out):
    font = ImageFont.truetype(next(p for p in FONTS if os.path.exists(p)), 22)
    images = [(label, Image.open(path).convert("RGB").crop(crop)) for label, path in cells]
    width = sum(im.width for _, im in images) + 12 * (len(images) + 1)
    sheet = Image.new("RGB", (width, max(im.height for _, im in images) + 56), (236, 236, 240))
    draw = ImageDraw.Draw(sheet)
    x = 12
    for label, im in images:
        draw.text((x + 4, 12), label, fill=(20, 20, 24), font=font)
        sheet.paste(im, (x, 46))
        x += im.width + 12
    sheet.save(out)
    print(out)


def main():
    pages, out, target = (Path(a) for a in sys.argv[1:4])
    target.mkdir(parents=True, exist_ok=True)
    def cells(name, source, other, first, last):
        return [(first, pages / f"{name}-{source}@1x.png"), ("现有版本", out / f"{name}-{source}@1x.current.png"),
                ("V2 原型", out / f"{name}-{source}@1x.v2.png"), (last, pages / f"{name}-{other}@1x.png")]
    strip(cells("apple", "en", "zh", "原图（英文）", "苹果自己的中文版（目标）"), (140, 0, 1140, 800), target / "apple-en-zh.png")
    strip(cells("ghdocs", "en", "zh", "原图（英文）", "GitHub 自己的中文版（目标）"), (0, 0, 1280, 900), target / "ghdocs-en-zh.png")
    strip(cells("app", "en", "zh", "原图（英文）", "真实中文版（目标）"), (0, 0, 1200, 880), target / "app-en-zh.png")
    strip(cells("app", "zh", "en", "原图（中文）", "真实英文版（目标）"), (0, 0, 1200, 880), target / "app-zh-en.png")
    strip(cells("appdark", "en", "zh", "原图（英文，深色）", "真实中文版（目标）"), (0, 0, 1200, 880), target / "appdark-en-zh.png")


if __name__ == "__main__":
    main()
