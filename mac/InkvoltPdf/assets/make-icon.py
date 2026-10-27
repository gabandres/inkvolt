"""Generates Inkvolt PDF's macOS icons as iconsets (16-1024 px, @1x and @2x) with 512 px previews:

  AppIcon.iconset         the app icon (CFBundleIconFile AppIcon)
  PdfDocument.iconset     the .pdf document icon (CFBundleTypeIconFile PdfDocument)
  InkvoltPdf-mac-512.png, PdfDocument-mac-512.png   previews

The app icon is the Windows icon's artwork (pdf/assets/make-icon.py's draw_app, "Vivid Fold" in amber to pink) on the
macOS tile Inkvolt Print's Mac icon uses (mac/InkvoltPrint/assets/make-icon.py: an 824 px rounded tile on a 1024 px
canvas, a soft shadow below), so both Mac apps look like one suite. Drawn at 1024 px and downsampled.

The document icon is the Windows file-type icon (draw_doc: a white page with a "PDF" band) as it is: a macOS document
icon is the page itself, without a tile. Each size is drawn on its own, as on Windows (bolder shapes at 24 px and below,
no lettering under 32 px).

build.sh and release.sh turn the iconsets into .icns with iconutil on the Mac (mac/InkvoltPdf/assemble.sh).
Run:  python -I mac/InkvoltPdf/assets/make-icon.py   (needs Pillow; on Windows, for draw_doc's Segoe UI Bold)
"""
import importlib.util
import os
import shutil
import sys

from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "shared", "assets"))
spec = importlib.util.spec_from_file_location("pdf_icon", os.path.join(ROOT, "pdf", "assets", "make-icon.py"))
pdf_icon = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pdf_icon)

CANVAS, TILE, RADIUS = 1024, 824, 185  # as Inkvolt Print's Mac icon
ART = 660  # the sheet alone, as tall as Print's sheet over its printer (600 there)
SIZES = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]


def icon():
    img = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    x0 = (CANVAS - TILE) // 2
    box = (x0, x0, x0 + TILE, x0 + TILE)

    # Shadow under the tile.
    shadow = Image.new("L", (CANVAS, CANVAS), 0)
    ImageDraw.Draw(shadow).rounded_rectangle((box[0], box[1] + 12, box[2], box[3] + 12), RADIUS, fill=90)
    img.paste((0, 0, 0, 255), (0, 0, CANVAS, CANVAS), shadow.filter(ImageFilter.GaussianBlur(14)))

    # The tile: white to a faint warm tint, top to bottom (Print's goes to a faint blue, after its sheet's colors).
    grad = Image.new("RGBA", (1, TILE))
    for y in range(TILE):
        t = y / (TILE - 1)
        grad.putpixel((0, y), (255, round(255 - 9 * t), round(255 - 12 * t), 255))
    grad = grad.resize((TILE, TILE))
    mask = Image.new("L", (TILE, TILE), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, TILE - 1, TILE - 1), RADIUS, fill=255)
    img.paste(grad, (x0, x0), mask)
    ImageDraw.Draw(img).rounded_rectangle(box, RADIUS, outline=(0, 0, 0, 22), width=2)

    # The Windows icon's artwork, centred.
    art = pdf_icon.draw_app(ART)
    img.alpha_composite(art, ((CANVAS - ART) // 2, (CANVAS - ART) // 2 + 6))
    return img


def iconset(name, image_for):
    folder = os.path.join(HERE, f"{name}.iconset")
    shutil.rmtree(folder, ignore_errors=True)
    os.makedirs(folder)
    for size, scale in SIZES:
        image_for(size * scale).save(os.path.join(folder, f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"))


def main():
    big = icon()
    iconset("AppIcon", lambda px: big.resize((px, px), Image.LANCZOS))
    big.resize((512, 512), Image.LANCZOS).save(os.path.join(HERE, "InkvoltPdf-mac-512.png"))
    iconset("PdfDocument", pdf_icon.draw_doc)
    pdf_icon.draw_doc(512).save(os.path.join(HERE, "PdfDocument-mac-512.png"))
    print(f"wrote AppIcon.iconset, PdfDocument.iconset and the previews in {HERE}")


if __name__ == "__main__":
    main()
