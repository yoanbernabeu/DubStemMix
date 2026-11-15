"""Artwork for the plugin's MPC screen, drawn like the Mac app (Sources/DubStemMix/Controls.swift, Theme.swift,
PRD § 5.11): flat cards, knobs as a thick arc in the bus colour, cream fader cap, segmented meters, outlined
strip buttons filled when lit, labels in Archivo. The MPC cannot load fonts, so every fixed text is drawn here
with the app's own fonts; what changes (names, values) stays in the MPC's fonts.
"""

import math
import os

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
FONTS = os.path.join(ROOT, "Sources", "DubStemMix", "Resources", "Fonts")

BG, SURFACE, BORDER = (0x14, 0x11, 0x0F), (0x1E, 0x1A, 0x17), (0x2E, 0x28, 0x23)
TEXT, TEXT2 = (0xED, 0xE3, 0xCF), (0x9A, 0x8F, 0x7E)
DELAY, REVERB, BUS3, RED = (0xD9, 0xA4, 0x41), (0x7E, 0x9B, 0x5A), (0xC2, 0x55, 0x3A), (0xE5, 0x41, 0x2D)
SS = 3   # supersampling, for clean edges


def label_font(size, weight=750, width=112):
    f = ImageFont.truetype(os.path.join(FONTS, "Archivo-Variable.ttf"), int(size * SS))
    f.set_variation_by_axes([weight, width])
    return f


def mono_font(size, weight=500):
    f = ImageFont.truetype(os.path.join(FONTS, "JetBrainsMono-Variable.ttf"), int(size * SS))
    f.set_variation_by_axes([weight])
    return f


def canvas(w, h, fill=(0, 0, 0, 0)):
    img = Image.new("RGBA", (w * SS, h * SS), fill)
    return img, ImageDraw.Draw(img)


def save(img, folder, name):
    w, h = img.size
    img.resize((w // SS, h // SS), Image.LANCZOS).save(os.path.join(folder, name), optimize=True)
    return name


def mix(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def text(d, xy, s, font, fill, anchor="mm", tracking=0):
    """Draws `s` centred on `xy` (supersampled coordinates), with letter spacing like the app's .tracking."""
    if not tracking:
        d.text(xy, s, font=font, fill=fill, anchor=anchor)
        return
    widths = [d.textlength(c, font=font) for c in s]
    total = sum(widths) + tracking * SS * (len(s) - 1)
    x = xy[0] - total / 2 if anchor[0] == "m" else xy[0]
    for c, w in zip(s, widths):
        d.text((x, xy[1]), c, font=font, fill=fill, anchor="l" + anchor[1])
        x += w + tracking * SS


# --- knobs --------------------------------------------------------------------------------------------------------

KNOB = 60
KNOB_FRAMES = 101


def knob_strip(folder, name, colour):
    """A film strip of KNOB_FRAMES frames: the app's knob (arc in the bus colour, surface disc, pointer)."""
    size = KNOB * SS
    strip = Image.new("RGBA", (size, size * KNOB_FRAMES), (0, 0, 0, 0))
    line = size * 0.14
    for f in range(KNOB_FRAMES):
        v = f / (KNOB_FRAMES - 1)
        frame = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        d = ImageDraw.Draw(frame)
        r = (size - line) / 2
        box = [size / 2 - r, size / 2 - r, size / 2 + r, size / 2 + r]
        d.arc(box, 135, 405, fill=BORDER, width=int(line))
        if v > 0.005:
            d.arc(box, 135, 135 + 270 * v, fill=colour, width=int(line))
            for a in (135, 135 + 270 * v):   # round caps
                cx = size / 2 + r * math.cos(math.radians(a))
                cy = size / 2 + r * math.sin(math.radians(a))
                d.ellipse([cx - line / 2, cy - line / 2, cx + line / 2, cy + line / 2], fill=colour)
        else:
            cx, cy = size / 2 + r * math.cos(math.radians(135)), size / 2 + r * math.sin(math.radians(135))
            d.ellipse([cx - line / 2, cy - line / 2, cx + line / 2, cy + line / 2], fill=BORDER)
            cx, cy = size / 2 + r * math.cos(math.radians(45)), size / 2 + r * math.sin(math.radians(45))
            d.ellipse([cx - line / 2, cy - line / 2, cx + line / 2, cy + line / 2], fill=BORDER)
        inner = size * 0.3
        d.ellipse([size / 2 - inner, size / 2 - inner, size / 2 + inner, size / 2 + inner], fill=SURFACE, outline=BORDER, width=SS * 2)
        # Pointer: a capsule from the centre towards the value.
        a = math.radians(-225 + 270 * v)
        p0 = (size / 2 + inner * 0.25 * math.cos(a), size / 2 + inner * 0.25 * math.sin(a))
        p1 = (size / 2 + inner * 0.85 * math.cos(a), size / 2 + inner * 0.85 * math.sin(a))
        d.line([p0, p1], fill=colour if v > 0.005 else TEXT2, width=int(size * 0.07))
        strip.paste(frame, (0, size * f))
    return save(strip, folder, name)


# --- cards --------------------------------------------------------------------------------------------------------

CARD_W, CARD_H = 150, 582
KNOB_Y = [28, 122, 216]          # knob tops inside the card
CAPTION_DY = KNOB + 3            # caption under the knob
NAME_Y = 332                     # strip name (centre)
BUTTON_Y = [352, 386]            # MUTE, REC ARM buttons
BUTTON = (130, 30)
FADER_Y, FADER_H = 422, 138      # fader travel area
FADER_X, METER_X, METER_W = 34, 96, 8
METER_SEGMENTS = 20


def meter_colour(threshold):
    if threshold >= 0.9:
        return RED
    if threshold >= 0.72:
        return DELAY
    return REVERB


def meter_ladder(d, x, y, w, h, lit):
    """The app's segmented meter, bottom up: sage, then ocre, then red."""
    seg = h / METER_SEGMENTS
    for i in range(METER_SEGMENTS):
        threshold = i / METER_SEGMENTS
        top = y + h - (i + 1) * seg + SS
        colour = meter_colour(threshold) if lit else mix(BORDER, SURFACE, 0.3)
        d.rounded_rectangle([x, top, x + w, top + seg - 2 * SS], radius=SS, fill=colour)


def card(folder, name, number, accent, tint, captions):
    """A strip card: number, knob captions (text, colour) or None, fader track, unlit meter."""
    img, d = canvas(CARD_W, CARD_H)
    fill = mix(BG, accent, 0.10) if tint else SURFACE
    outline = mix(BORDER, accent, 0.55) if tint else BORDER
    d.rounded_rectangle([SS, SS, (CARD_W - 1) * SS, (CARD_H - 1) * SS], radius=8 * SS, fill=fill, outline=outline, width=int(1.5 * SS))
    if number:
        n, rest = number
        f = label_font(13, 800)
        if rest:
            wn, wr = d.textlength(n + " ", font=f), d.textlength(rest, font=f)
            x0 = CARD_W * SS / 2 - (wn + wr) / 2
            d.text((x0, 16 * SS), n + " ", font=f, fill=TEXT2, anchor="lm")
            d.text((x0 + wn, 16 * SS), rest, font=f, fill=accent, anchor="lm")
        else:
            d.text((CARD_W * SS / 2, 16 * SS), n, font=f, fill=TEXT2, anchor="mm")
    for row, cap in enumerate(captions):
        if cap:
            text(d, (CARD_W * SS / 2, (KNOB_Y[row] + CAPTION_DY + 6) * SS), cap[0], label_font(11, 800), cap[1], tracking=0.5)
    # Fader track (the cap is a separate image that slides on it) and the unlit meter.
    cx = (FADER_X + 22) * SS
    d.rounded_rectangle([cx - 2 * SS, (FADER_Y + 4) * SS, cx + 2 * SS, (FADER_Y + FADER_H - 4) * SS], radius=2 * SS, fill=BORDER)
    meter_ladder(d, METER_X * SS, (FADER_Y + 4) * SS, METER_W * SS, (FADER_H - 8) * SS, False)
    return save(img, folder, name)


def name_image(folder, name, title, colour, w=CARD_W, h=30):
    img, d = canvas(w, h)
    text(d, (w * SS / 2, h * SS / 2), title, label_font(20, 850), colour, tracking=1)
    return save(img, folder, name)


def button(folder, name, title, lit, colour):
    w, h = BUTTON
    img, d = canvas(w, h)
    box = [SS, SS, (w - 1) * SS, (h - 1) * SS]
    if lit:
        d.rounded_rectangle(box, radius=4 * SS, fill=colour, outline=colour, width=int(1.5 * SS))
    else:
        d.rounded_rectangle(box, radius=4 * SS, outline=BORDER, width=int(1.5 * SS))
    text(d, (w * SS / 2, h * SS / 2 + SS), title, label_font(12, 800), BG if lit else TEXT2, tracking=1)
    return save(img, folder, name)


def fader_cap(folder):
    img, d = canvas(36, 26)
    d.rounded_rectangle([0, 0, 36 * SS - 1, 26 * SS - 1], radius=3 * SS, fill=TEXT)
    d.rectangle([0, 12 * SS, 36 * SS, 14 * SS], fill=BG)
    return save(img, folder, "fader_cap.png")


def meter_lit(folder):
    img, d = canvas(METER_W, FADER_H - 8)
    meter_ladder(d, 0, 0, METER_W * SS, (FADER_H - 8) * SS, True)
    return save(img, folder, "meter_lit.png")


def blank(folder):
    Image.new("RGBA", (1, 1), (0, 0, 0, 0)).save(os.path.join(folder, "blank.png"))
    return "blank.png"


def logo(folder):
    """DUBSTEMMIX, as in the app's corner: DUB ocre, STEM sage, MIX brick."""
    w, h = 230, 36
    img, d = canvas(w, h)
    f = label_font(23, 900, 125)
    x = 2 * SS
    for part, colour in (("DUB", DELAY), ("STEM", REVERB), ("MIX", BUS3)):
        d.text((x, h * SS / 2), part, font=f, fill=colour, anchor="lm")
        x += d.textlength(part, font=f)
    return save(img, folder, "logo.png")


def page_pill(folder, title, lit):
    w, h = 64, 30
    img, d = canvas(w, h)
    box = [SS, SS, (w - 1) * SS, (h - 1) * SS]
    if lit:
        d.rounded_rectangle(box, radius=4 * SS, fill=TEXT)
    else:
        d.rounded_rectangle(box, radius=4 * SS, outline=BORDER, width=int(1.5 * SS))
    text(d, (w * SS / 2, h * SS / 2 + SS), title, label_font(13, 850), BG if lit else TEXT2, tracking=1)
    return save(img, folder, "page_%s_%s.png" % (title.lower(), "on" if lit else "off"))
