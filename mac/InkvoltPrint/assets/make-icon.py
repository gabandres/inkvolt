"""Generates Inkvolt Print's macOS app icon: Resources/Assets.xcassets/AppIcon.appiconset (16-1024 px) and a preview.

macOS icons sit on a rounded square tile with room around it (Apple's grid: an 824 px tile on a 1024 px canvas, corners
about 22% of the tile, a soft shadow below). The artwork is the Windows icon's ("Vivid Fold": print/assets/make-icon.py,
drawn with shared/assets/iconkit.py) on a light tile, so the suite looks the same on both systems. Each size is drawn at
1024 px and box-downsampled.

Run:  python -I mac/InkvoltPrint/assets/make-icon.py   (needs Pillow)
"""
import importlib.util
import json
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "shared", "assets"))
spec = importlib.util.spec_from_file_location("print_icon", os.path.join(ROOT, "print", "assets", "make-icon.py"))
print_icon = importlib.util.module_from_spec(spec)
spec.loader.exec_module(print_icon)

CANVAS, TILE, RADIUS, ART = 1024, 824, 185, 600
SET = os.path.join(HERE, "..", "Resources", "Assets.xcassets", "AppIcon.appiconset")
SIZES = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]


def icon():
    img = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    x0 = (CANVAS - TILE) // 2
    box = (x0, x0, x0 + TILE, x0 + TILE)

    # Shadow under the tile.
    shadow = Image.new("L", (CANVAS, CANVAS), 0)
    ImageDraw.Draw(shadow).rounded_rectangle((box[0], box[1] + 12, box[2], box[3] + 12), RADIUS, fill=90)
    img.paste((0, 0, 0, 255), (0, 0, CANVAS, CANVAS), shadow.filter(ImageFilter.GaussianBlur(14)))

    # The tile: white to a faint blue, top to bottom.
    grad = Image.new("RGBA", (1, TILE))
    for y in range(TILE):
        t = y / (TILE - 1)
        grad.putpixel((0, y), (round(255 - 14 * t), round(255 - 10 * t), 255, 255))
    grad = grad.resize((TILE, TILE))
    mask = Image.new("L", (TILE, TILE), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, TILE - 1, TILE - 1), RADIUS, fill=255)
    img.paste(grad, (x0, x0), mask)
    ImageDraw.Draw(img).rounded_rectangle(box, RADIUS, outline=(0, 0, 0, 22), width=2)

    # The Windows icon's artwork, centred.
    art = print_icon.draw(ART)
    img.alpha_composite(art, ((CANVAS - ART) // 2, (CANVAS - ART) // 2 + 6))
    return img


def main():
    big = icon()
    os.makedirs(SET, exist_ok=True)
    images = []
    for size, scale in SIZES:
        px = size * scale
        name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
        big.resize((px, px), Image.LANCZOS).save(os.path.join(SET, name))
        images.append({"idiom": "mac", "scale": f"{scale}x", "size": f"{size}x{size}", "filename": name})
    with open(os.path.join(SET, "Contents.json"), "w", newline="\r\n") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")
    with open(os.path.join(SET, "..", "Contents.json"), "w", newline="\r\n") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")
    big.resize((512, 512), Image.LANCZOS).save(os.path.join(HERE, "InkvoltPrint-mac-512.png"))


if __name__ == "__main__":
    main()
