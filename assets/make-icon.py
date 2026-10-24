"""Generates assets/InkvoltPrint.ico (16-256 px), a 512 px preview PNG, and the MSIX images.

Design ("Vivid Fold", shared with Inkvolt PDF): no tile, per Windows 11 app icon guidance. The suite's folded sheet
with a white bolt, in electric cyan to volt blue, feeds into an indigo printer with a cyan status light. Small sizes
(24 px and below) use bolder shapes and drop the printed sheet; 16-20 px also drop the light. Shapes are drawn in a
48-unit grid (assets/iconkit.py, shared with Inkvolt PDF) at about 1024 px, then box-downsampled to each size.

packaging/Assets/*.png: MSIX images (tiles, Start/taskbar icons per target size, store logo, splash screen), named with
MRT qualifiers (scale-N, targetsize-N, altform-unplated) that makepri indexes into resources.pri
(packaging/pack-msix.ps1). Same set as Inkvolt PDF's, minus its PDF file-type logo (Inkvolt Print's "Open with" entry for PDFs
uses the app icon).

assets/tray/InkvoltPrint-{warning,error,offline}.ico: the notification-area icon with a status badge (amber "!", red "x",
grey "-"), one frame per small-icon size (16-64 px: 100-400% scale), so the tray icon is drawn 1:1 at every DPI. The OK
state is InkvoltPrint.ico itself. `make-icon.py --tray` writes only these (and assets/tray/tray-sheet.png for review).

Run:  python -I assets/make-icon.py [--tray]   (needs Pillow)
"""
import os
import sys
from PIL import Image, ImageChops, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)  # python -I leaves the script's folder off the path
from iconkit import Canvas, Grad, bolt_pts, inter, page_pts, sub  # noqa: E402

SIZES = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]


def lvl(size):
    return "s" if size <= 24 else "m" if size <= 48 else "l"


SHEET = [(0, "#3FD8FF"), (0.6, "#3E86FF"), (1, "#4B4BEA")]  # electric cyan -> volt blue (Inkvolt PDF: coral -> pink)


def folded_sheet(c, box, f, L, bolt_h, bolt_dy):
    """The suite's folded sheet: gradient page, soft fold, white bolt."""
    x0, y0, x1, y1 = box
    pg = c.poly(page_pts(*box, f), [2.4, 0.8, 0.8, 2.4, 2.4])
    c.shadow(pg, dy=0.9, blur=1.2, alpha=0.22)
    c.fill(pg, Grad((x0, y0), (x1, y1), SHEET))
    fold = c.poly([(x1 - f, y0), (x1 - f, y0 + f), (x1, y0 + f)], [0.6, 2.0, 0.6])
    c.shadow(fold, dy=0.8, dx=-0.6, blur=1.0, color=(90, 0, 40), alpha=0.35, clip=pg)
    c.fill(fold, Grad((x1 - f, y0), (x1, y0 + f), [(0, (255, 255, 255, 235)), (1, (255, 255, 255, 150))]))
    bolt = c.poly(bolt_pts((x0 + x1) / 2, (y0 + y1) / 2 + bolt_dy, bolt_h), 0.7)
    if L != "s":
        c.shadow(bolt, dy=0.8, blur=0.9, color=(60, 0, 40), alpha=0.25, clip=pg)
    c.fill(bolt, "#FFFFFF")


def draw(size):
    c = Canvas(size)
    L = lvl(size)
    s = L == "s"
    tiny = size <= 20
    box = (11, 2, 37, 32) if not s else (9, 1, 39, 32)
    body = (3, 25, 45, 44) if not s else (1, 24, 47, 46)
    bolt_h, bolt_dy = (13, -1.5) if not s else (15, -1.5)
    if tiny:  # more sheet above a slimmer printer, so the bolt keeps its zigzag
        box, body, bolt_h, bolt_dy = (8, 0, 40, 34), (1, 28, 47, 47), 21, -3.5
    folded_sheet(c, box, 9 if not s else 10, L, bolt_h, bolt_dy)
    bd = c.rrect(*body, 6 if not s else 5)
    c.shadow(bd, dy=-0.6, blur=1.2, color=(10, 20, 80), alpha=0.35)
    c.shadow(bd, dy=1.0, blur=1.2, alpha=0.22)
    c.fill(bd, Grad((body[0], body[1]), (body[2], body[3]), [(0, "#4C3FE0"), (1, "#2A1F96")]))
    c.fill(inter(bd, c.rrect(body[0], body[1], body[2], body[1] + 1.2, 0)), "#FFFFFF", 0.22)
    slot = (11, 33, 37, 36.5) if not s else (7, 33, 35, 37.5)
    if tiny:
        slot = (6, 35.5, 42, 40.5)  # one bold slot, no status light: 16-20 px can't hold more
    c.fill(c.rrect(*slot, 1.75), "#17105A")
    if not s:
        # the printed sheet coming out of the slot
        o = c.rrect(slot[0] + 3, slot[1] + 1.75, slot[2] - 3, 47, 1.6)
        o = sub(o, c.rrect(0, 0, 48, slot[1] + 1.75, 0))
        c.shadow(o, dy=0.5, blur=0.6, color=(10, 10, 60), alpha=0.35)
        c.fill(o, Grad((0, slot[1]), (0, 47), [(0, "#DCE6FF"), (1, "#FFFFFF")]))
        c.fill(c.rrect(slot[0], slot[1], slot[2], slot[1] + 1.9, 0.9), "#17105A")
    if not tiny:
        r = 1.8 if not s else 2.6
        cx, cy = (41, 34.75) if not s else (40.5, 35.25)
        c.fill(c.ellipse(cx - r, cy - r, cx + r, cy + r), "#5CF0FF")
    return c.out()


# Notification-area icons: the small-icon size at 100, 125, 150, 200, 250, 300 and 400% scale.
TRAY_SIZES = [16, 20, 24, 32, 40, 48, 64]
# state: (badge color, glyph color, glyph)
BADGES = {"warning": ("#FFB900", "#1B1B1B", "!"), "error": ("#E5202E", "#FFFFFF", "x"), "offline": ("#767676", "#FFFFFF", "-")}


def rotated_bar(c, cx, cy, length, width, degrees):
    """A rounded bar centered on (cx, cy), turned by degrees (design units)."""
    import math
    a = math.radians(degrees)
    dx, dy = math.cos(a), math.sin(a)
    nx, ny = -dy, dx
    hl, hw = length / 2, width / 2
    pts = [(cx - dx * hl - nx * hw, cy - dy * hl - ny * hw), (cx + dx * hl - nx * hw, cy + dy * hl - ny * hw),
           (cx + dx * hl + nx * hw, cy + dy * hl + ny * hw), (cx - dx * hl + nx * hw, cy - dy * hl + ny * hw)]
    return c.poly(pts, width * 0.3)


def tray(size, state):
    """The app icon with a status badge in its lower right corner, cut out of the icon by a thin transparent ring."""
    fill, ink, glyph = BADGES[state]
    base = draw(size)
    c = Canvas(size)
    r = 12.0 if size <= 24 else 10.5  # small sizes: an 8 px badge at 16 px
    cx = cy = 48 - r
    gap = 2.4 if size <= 24 else 2.0
    ring = c.ellipse(cx - r - gap, cy - r - gap, cx + r + gap, cy + r + gap).resize((size, size), Image.BOX)
    base.putalpha(ImageChops.subtract(base.getchannel("A"), ring))
    c.fill(c.ellipse(cx - r, cy - r, cx + r, cy + r), fill)
    w = r * 0.42
    if glyph == "!":
        mark = c.rrect(cx - w / 2, cy - r * 0.62, cx + w / 2, cy + r * 0.2, w / 2)
        mark = ImageChops.lighter(mark, c.ellipse(cx - w / 2, cy + r * 0.36, cx + w / 2, cy + r * 0.36 + w))
    elif glyph == "x":
        mark = ImageChops.lighter(rotated_bar(c, cx, cy, r * 1.15, w, 45), rotated_bar(c, cx, cy, r * 1.15, w, -45))
    else:
        mark = c.rrect(cx - r * 0.58, cy - w / 2, cx + r * 0.58, cy + w / 2, w / 2)
    c.fill(mark, ink)
    base.alpha_composite(c.out())
    return base


def save_tray():
    folder = os.path.join(HERE, "tray")
    os.makedirs(folder, exist_ok=True)
    sheet = Image.new("RGBA", (len(BADGES) * (sum(TRAY_SIZES) + 8 * len(TRAY_SIZES)) + 24, 2 * 64 + 36), (255, 255, 255, 255))
    ImageDraw.Draw(sheet).rectangle([0, 64 + 18, sheet.width, sheet.height], fill=(32, 32, 32, 255))
    x = 12
    for state in BADGES:
        frames = [tray(s, state) for s in TRAY_SIZES]
        frames[-1].save(os.path.join(folder, f"InkvoltPrint-{state}.ico"), format="ICO", sizes=[(s, s) for s in TRAY_SIZES],
                        append_images=frames[:-1])
        for f in frames:
            sheet.alpha_composite(f, (x, 64 - f.height + 6))
            sheet.alpha_composite(f, (x, 2 * 64 + 24 - f.height))
            x += f.width + 8
    sheet.save(os.path.join(folder, "tray-sheet.png"))
    return folder


# MSIX images. Base sizes are the scale-100 sizes; each is written at these scales.
SCALES = [100, 125, 150, 200, 400]
TARGET_SIZES = [16, 20, 24, 30, 32, 36, 40, 48, 60, 64, 72, 80, 96, 256]  # every size Windows asks for
# name: (width, height, icon size as a fraction of the shorter side)
TILES = {
    "Square44x44Logo": (44, 44, 1.0),
    "Square71x71Logo": (71, 71, 0.7),
    "Square150x150Logo": (150, 150, 0.6),
    "Wide310x150Logo": (310, 150, 0.6),
    "Square310x310Logo": (310, 310, 0.5),
    "StoreLogo": (50, 50, 1.0),
    "SplashScreen": (620, 300, 0.5),
}


def centered(w, h, frac):
    """The icon drawn at frac of the shorter side, centered on a transparent w x h canvas."""
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    icon = draw(max(16, round(min(w, h) * frac)))
    img.paste(icon, ((w - icon.width) // 2, (h - icon.height) // 2), icon)
    return img


def save_msix(folder):
    os.makedirs(folder, exist_ok=True)
    for old in os.listdir(folder):
        if old.lower().endswith(".png"):
            os.remove(os.path.join(folder, old))
    count = 0
    for name, (w, h, frac) in TILES.items():
        for scale in SCALES:
            centered(round(w * scale / 100), round(h * scale / 100), frac).save(os.path.join(folder, f"{name}.scale-{scale}.png"))
            count += 1
    # Taskbar, Start list and title bar pick an exact pixel size. No tile, so plated and unplated are one image; its
    # colors keep their contrast on both the light and the dark taskbar.
    for size in TARGET_SIZES:
        app = draw(size)
        for suffix in ("", "_altform-unplated", "_altform-lightunplated"):
            app.save(os.path.join(folder, f"Square44x44Logo.targetsize-{size}{suffix}.png"))
            count += 1
    return count


def main():
    if "--tray" in sys.argv[1:]:
        print("wrote", save_tray())
        return
    frames = [draw(s) for s in SIZES]
    ico = os.path.join(HERE, "InkvoltPrint.ico")
    frames[-1].save(ico, format="ICO", sizes=[(s, s) for s in SIZES], append_images=frames[:-1])
    draw(512).save(os.path.join(HERE, "InkvoltPrint-512.png"))
    # Contact sheet for review: every size on white and on dark.
    sheet = Image.new("RGBA", (sum(SIZES) + 12 * len(SIZES) + 12, 2 * 256 + 36), (255, 255, 255, 255))
    ImageDraw.Draw(sheet).rectangle([0, 256 + 18, sheet.width, sheet.height], fill=(32, 32, 32, 255))
    x = 12
    for f in frames:
        sheet.alpha_composite(f, (x, 256 - f.height + 6))
        sheet.alpha_composite(f, (x, 2 * 256 + 24 - f.height))
        x += f.width + 12
    sheet.save(os.path.join(HERE, "icon-sheet.png"))
    n = save_msix(os.path.join(HERE, "..", "packaging", "Assets"))
    save_tray()
    print("wrote", ico, f", {n} MSIX images in packaging/Assets and the tray icons in assets/tray")


if __name__ == "__main__":
    main()
