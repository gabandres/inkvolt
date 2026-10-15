"""Generates assets/PrintDesk.ico (16-256 px) and a 512 px preview PNG.

Design: Fluent-style rounded tile in Windows blue; a white printer with a document feeding in on top;
a green status light (the same "ready" dot the app uses). Tiny sizes drop detail to stay legible.
Every size is drawn at 8x and downsampled, so edges are clean at each size rather than one image scaled.

Run:  python -I assets/make-icon.py   (needs Pillow)
"""
import os
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
SIZES = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def draw(size):
    ss = 8
    n = size * ss
    u = n / 100.0  # design units: 0..100
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))

    def box(x0, y0, x1, y1):
        return [round(x0 * u), round(y0 * u), round(x1 * u), round(y1 * u)]

    tiny = size <= 24
    small = size <= 48

    # Tile: vertical gradient, rounded square.
    grad = Image.new("RGBA", (n, n))
    gd = ImageDraw.Draw(grad)
    top, bottom = (54, 148, 255, 255), (16, 92, 214, 255)
    for y in range(n):
        gd.line([(0, y), (n, y)], fill=lerp(top, bottom, y / n))
    mask = Image.new("L", (n, n), 0)
    margin = 2 if not tiny else 0
    ImageDraw.Draw(mask).rounded_rectangle(box(margin, margin, 100 - margin, 100 - margin), radius=round(22 * u), fill=255)
    img.paste(grad, (0, 0), mask)
    d = ImageDraw.Draw(img)

    # Soft top highlight on the tile (large sizes only).
    if not small:
        hl = Image.new("RGBA", (n, n), (0, 0, 0, 0))
        ImageDraw.Draw(hl).rounded_rectangle(box(margin, margin, 100 - margin, 52), radius=round(22 * u), fill=(255, 255, 255, 22))
        img = Image.alpha_composite(img, Image.composite(hl, Image.new("RGBA", (n, n)), mask))
        d = ImageDraw.Draw(img)

    white = (255, 255, 255, 255)
    paper_edge = (214, 228, 250, 255)
    ink = (120, 150, 200, 255)
    dark = (12, 58, 140, 255)

    # Document feeding in on top (drawn first, printer body overlaps its bottom).
    if tiny:
        d.rounded_rectangle(box(30, 16, 70, 50), radius=round(3 * u), fill=white)
    else:
        d.rounded_rectangle(box(31, 15, 69, 50), radius=round(3.5 * u), fill=white, outline=paper_edge, width=max(1, round(1.2 * u)))
        for i, w in enumerate([30, 26, 30, 18]):
            y = 23 + i * 6
            d.rounded_rectangle(box(37, y, 37 + w * 0.88, y + 2.4), radius=round(1.2 * u), fill=ink)

    # Printer body.
    shadow = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(box(15, 43, 85, 79), radius=round(9 * u), fill=(0, 30, 90, 70))
    img = Image.alpha_composite(img, shadow.transform((n, n), Image.AFFINE, (1, 0, 0, 0, 1, -round(1.6 * u))))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle(box(15, 41, 85, 76), radius=round(9 * u), fill=white)

    # Output slot.
    d.rounded_rectangle(box(27, 63, 73, 67.5), radius=round(2.2 * u), fill=dark)

    # Output sheet peeking out of the slot (large sizes only).
    if not small:
        d.rounded_rectangle(box(31, 65, 69, 86), radius=round(3 * u), fill=white, outline=paper_edge, width=max(1, round(1.2 * u)))
        d.rounded_rectangle(box(27, 63, 73, 66), radius=round(1.5 * u), fill=dark)

    # Status light.
    r = 5.5 if tiny else 4.6
    cx, cy = 74, 51
    d.ellipse(box(cx - r - 1.6, cy - r - 1.6, cx + r + 1.6, cy + r + 1.6), fill=white)
    d.ellipse(box(cx - r, cy - r, cx + r, cy + r), fill=(46, 190, 96, 255))

    return img.resize((size, size), Image.LANCZOS)


def main():
    frames = [draw(s) for s in SIZES]
    ico = os.path.join(HERE, "PrintDesk.ico")
    frames[-1].save(ico, format="ICO", sizes=[(s, s) for s in SIZES], append_images=frames[:-1])
    draw(512).save(os.path.join(HERE, "PrintDesk-512.png"))
    # Contact sheet for review: every size on white and on dark.
    sheet = Image.new("RGBA", (sum(SIZES) + 12 * len(SIZES) + 12, 2 * 256 + 36), (255, 255, 255, 255))
    ImageDraw.Draw(sheet).rectangle([0, 256 + 18, sheet.width, sheet.height], fill=(32, 32, 32, 255))
    x = 12
    for f in frames:
        sheet.alpha_composite(f, (x, 256 - f.height + 6))
        sheet.alpha_composite(f, (x, 2 * 256 + 24 - f.height))
        x += f.width + 12
    sheet.save(os.path.join(HERE, "icon-sheet.png"))
    print("wrote", ico)


if __name__ == "__main__":
    main()
