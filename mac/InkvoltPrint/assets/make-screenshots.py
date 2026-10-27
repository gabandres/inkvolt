"""Composes Inkvolt Print's Mac App Store screenshots (1440 x 900, one of the sizes App Store Connect takes for macOS).

Input: window captures from the Debug build's snapshot mode, in demo mode (made-up printers, 192.0.2.x addresses, no
real device's identifiers):
    open "Inkvolt Print.app" --args --demo --snapshot laser:0,inkjet:1,cdm:3,office:2,snmp:4,scan:1:scan,photos:1:photos,print-photos:1:print-photos --wait 8
    open "Inkvolt Print.app" --args --demo --dark --snapshot dark-laser:0,dark-inkjet:1,dark-cdm:3 --wait 8
copied from the app's container into a folder. Each capture goes on the icon's blue-to-indigo gradient under a caption,
at 1:1 (the captures are 1180 x 720 at 1x), with a soft shadow.

Run:  python -I mac/InkvoltPrint/assets/make-screenshots.py <captures folder>   (needs Pillow; Segoe UI from Windows)
Writes mac/InkvoltPrint/assets/store/01-*.png ...
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "store")
W, H = 1440, 900
FONTS = os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "Fonts")

SHOTS = [
    ("laser", "Your printer at a glance", "Status, toner and pages printed, read straight from the printer."),
    ("dark-cdm", "Every cartridge, every color", "Levels, pages left, and the cartridge to buy when one runs low."),
    ("inkjet", "Not just HP", "Works with AirPrint, Mopria and IPP Everywhere printers from any brand."),
    ("office", "Knows when something's wrong", "Offline, low or jammed: the menu bar tells you, and so does a notification."),
    ("snmp", "Older network printers too", "Status, alerts and toner over SNMP when that's all a printer speaks."),
    ("scan", "Several photos, one scan", "Lay prints on the glass: each is found, cut out straight and saved on its own."),
    ("photos", "Adjust any photo by hand", "Move, resize or turn a box, or mark a photo the scan missed."),
    ("print-photos", "Print photos at their real size", "Pick the paper, paper type and quality; borderless where your printer offers it."),
]


def background():
    top, bottom = (63, 134, 255), (43, 31, 150)  # the icon's volt blue to its printer's indigo
    img = Image.new("RGB", (W, H))
    px = img.load()
    for y in range(H):
        for x in range(W):
            t = min(1.0, max(0.0, (y / H) * 0.8 + (x / W) * 0.2))
            px[x, y] = tuple(round(a + (b - a) * t) for a, b in zip(top, bottom))
    return img.convert("RGBA")


def compose(capture, title, subtitle, bg):
    img = bg.copy()
    d = ImageDraw.Draw(img)
    big = ImageFont.truetype(os.path.join(FONTS, "segoeuib.ttf"), 44)
    small = ImageFont.truetype(os.path.join(FONTS, "segoeui.ttf"), 22)
    d.text((W / 2, 52), title, font=big, fill=(255, 255, 255), anchor="mm")
    d.text((W / 2, 100), subtitle, font=small, fill=(225, 232, 255), anchor="mm")

    win = Image.open(capture).convert("RGBA")
    x, y = (W - win.width) // 2, 140
    shadow = Image.new("L", (W, H), 0)
    shadow.paste(win.getchannel("A").point(lambda a: 120 if a > 0 else 0), (x, y + 14))
    img.paste((10, 8, 40, 255), (0, 0, W, H), shadow.filter(ImageFilter.GaussianBlur(22)))
    img.alpha_composite(win, (x, y))
    return img.convert("RGB")


def main():
    captures = sys.argv[1]
    os.makedirs(OUT, exist_ok=True)
    bg = background()
    for i, (name, title, subtitle) in enumerate(SHOTS, 1):
        compose(os.path.join(captures, f"snapshot-{name}.png"), title, subtitle, bg).save(os.path.join(OUT, f"{i:02d}-{name}.png"))
        print(f"{i:02d}-{name}.png")


if __name__ == "__main__":
    main()
