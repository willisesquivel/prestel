"""Draws the DMG window background at 1x and 2x.

Usage: background.py OUT_DIR
Writes background.png (1x) and background@2x.png. Layout constants are shared
with settings.py so the art lines up with Finder's icon positions.
"""
import random
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

sys.path.insert(0, str(Path(__file__).parent))
from layout import APP, APPS, HEIGHT, ICON, WIDTH  # noqa: E402

BG_TOP = (22, 22, 25)
BG_BOTTOM = (11, 11, 13)
CREAM = (238, 232, 218)
DIM = (126, 124, 120)
RED = (255, 72, 64)
BLUE = (70, 110, 255)
SANS = "/System/Library/Fonts/SFNS.ttf"
MONO = "/System/Library/Fonts/SFNSMono.ttf"


def font(path, size, style):
    f = ImageFont.truetype(path, size)
    f.set_variation_by_name(style)
    return f


def tracked(d, xy, text, f, fill, tracking):
    """Draws text with extra space between letters; returns its width."""
    x, y = xy
    for ch in text:
        d.text((x, y), ch, font=f, fill=fill)
        x += d.textlength(ch, font=f) + tracking
    return x - xy[0] - tracking


def tracked_width(d, text, f, tracking):
    return sum(d.textlength(ch, font=f) for ch in text) + tracking * (len(text) - 1)


def render(scale):
    w, h = WIDTH * scale, HEIGHT * scale
    img = Image.new("RGB", (w, h))
    # Vertical gradient.
    grad = Image.linear_gradient("L").resize((w, h))
    img = Image.composite(Image.new("RGB", (w, h), BG_BOTTOM), Image.new("RGB", (w, h), BG_TOP), grad)

    # Warm glow behind the app icon and a cooler one behind Applications.
    def glow(center, radius, color, strength):
        layer = Image.new("RGB", (w, h), (0, 0, 0))
        d = ImageDraw.Draw(layer)
        cx, cy = center[0] * scale, center[1] * scale
        r = radius * scale
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=tuple(int(c * strength) for c in color))
        return layer.filter(ImageFilter.GaussianBlur(r * 0.55))

    img = ImageChops.add(img, glow(APP, 120, (255, 236, 205), 0.16))
    img = ImageChops.add(img, glow(APPS, 110, (150, 180, 255), 0.07))

    # CRT scanlines, one every 3 points.
    lines = Image.new("L", (w, h), 0)
    ld = ImageDraw.Draw(lines)
    step = 3 * scale
    for y in range(0, h, step):
        ld.rectangle((0, y, w, y + scale - 1), fill=255)
    img = Image.composite(ImageChops.multiply(img, Image.new("RGB", (w, h), (232, 232, 232))), img, lines)

    # Film grain.
    rnd = random.Random(7)
    noise = Image.frombytes("L", (w, h), bytes(rnd.randrange(0, 256) for _ in range(w * h)))
    grain = Image.merge("RGB", (noise, noise, noise))
    img = Image.blend(img, ImageChops.overlay(img, grain), 0.08)

    # Vignette.
    vignette = Image.new("L", (w, h), 0)
    ImageDraw.Draw(vignette).ellipse((-w * 0.25, -h * 0.35, w * 1.25, h * 1.35), fill=255)
    vignette = vignette.filter(ImageFilter.GaussianBlur(90 * scale))
    img = Image.composite(img, ImageChops.multiply(img, Image.new("RGB", (w, h), (120, 120, 120))), vignette)

    d = ImageDraw.Draw(img)

    # Wordmark.
    title = font(SANS, 30 * scale, "Semibold")
    text = "Prestel"
    tw = tracked_width(d, text, title, -0.4 * scale)
    tx, ty = (w - tw) / 2, 50 * scale
    tracked(d, (tx, ty), text, title, CREAM, -0.4 * scale)
    sub = font(MONO, 10 * scale, "Medium")
    tag = "A NATIVE MACOS TERMINAL"
    sw = tracked_width(d, tag, sub, 2.2 * scale)
    tracked(d, ((w - sw) / 2, ty + 46 * scale), tag, sub, DIM, 2.2 * scale)

    # Pixel chevrons between the icons, with the icon's red/blue fringe.
    px = 4 * scale
    chevron = [(0, 0), (1, 1), (2, 2), (3, 3), (2, 4), (1, 5), (0, 6)]
    gap_l = APP[0] + ICON / 2 + 26
    gap_r = APPS[0] - ICON / 2 - 26
    count = 3
    cw = 4 * px
    spacing = 9 * scale
    total = count * cw + (count - 1) * spacing
    start = ((gap_l + gap_r) / 2) * scale - total / 2
    cy = APP[1] * scale - 3.5 * px
    alphas = [0.35, 0.65, 1.0]
    for i in range(count):
        x0 = start + i * (cw + spacing)
        # Red and blue copies sit a pixel either side, then cream on top.
        for offset, color, a in ((-scale, RED, 0.7), (scale, BLUE, 0.7), (0, CREAM, 1.0)):
            fill = tuple(int(c * a * alphas[i]) for c in color)
            for cx, cyy in chevron:
                x = x0 + cx * px + offset
                y = cy + cyy * px
                d.rectangle((x, y, x + px - 1, y + px - 1), fill=fill)

    # Terminal-style hint.
    hint = font(MONO, 12 * scale, "Regular")
    prompt, rest = "> ", "drag Prestel into Applications"
    full = prompt + rest
    fw = d.textlength(full, font=hint)
    hx, hy = (w - fw) / 2 - 6 * scale, (HEIGHT - 50) * scale
    d.text((hx, hy), prompt, font=hint, fill=CREAM)
    d.text((hx + d.textlength(prompt, font=hint), hy), rest, font=hint, fill=DIM)
    cx = hx + fw + 3 * scale
    d.rectangle((cx, hy + 2 * scale, cx + 7 * scale, hy + 15 * scale), fill=CREAM)
    return img


if __name__ == "__main__":
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    render(1).save(out / "background.png")
    render(2).save(out / "background@2x.png")
