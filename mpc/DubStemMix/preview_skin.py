#!/usr/bin/env python3
"""Renders the plugin's MPC screen (skins/TUI.json) to PNG with demo values, for the docs and the website.

A rendering of the screen files, not the MPC's own renderer: layout, images and visibility are exact; the
changing text uses the app's fonts in place of the MPC's (Nexa, Roboto).
Usage: python3 preview_skin.py <out folder>   -> mpc-console.png, mpc-fx.png, mpc-song.png, mpc-setup.png, mpc-pads.png
"""

import json
import math
import os
import re
import sys

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_skin as m  # noqa: E402
import skin_art as art  # noqa: E402

SKIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "skins")


def demo():
    """A set in full swing: song 3 playing, 4 next, sends up, a throw held, the bass muted."""
    v, t = {}, {}
    for s in range(6):
        v[m.fader(s)] = [0.82, 0.9, 0.7, 0.76, 0.8, 0.8][s]
    for s, b, val in [(0, 0, .45), (0, 1, .2), (1, 0, .3), (1, 2, .1), (2, 1, .55), (3, 0, .7), (3, 1, .35)]:
        v[m.send(s, b)] = val
    v[m.MODE5] = v[m.MODE6] = 1
    v[m.LAMP_MUTE1 + 1] = 1
    v[m.LAMP_REC1 + 3] = 1
    for s, level in enumerate([0.85, 0.0, 0.7, 0.8, 0.55, 0.0, 0.62, 0.48]):
        v[m.METER1 + s] = level
    for name, val in [("delayReturn", .9), ("reverbReturn", .85), ("delayTime", .62), ("delayFeedback", .58),
                      ("reverbDecay", .7), ("phaserRate", .35), ("delayToReverb", .3), ("reverbSend", 0),
                      ("sirenPitch", .5), ("sirenRate", .45), ("sirenDelay", .5), ("syndrumPitch", .4),
                      ("syndrumDecay", .5), ("syndrumDelay", .5), ("delayWow", .25), ("delayLowCut", .45),
                      ("delayHighCut", .55), ("reverbDamping", .4), ("reverbPredelay", .1), ("reverbLowCut", .55),
                      ("reverbTone", .65), ("phaserDepth", .75), ("phaserFeedback", .74), ("phaserCenter", .5),
                      ("phaserStereo", .5), ("phaserReturn", 1), ("killBass", 1), ("killMid", 1), ("killTop", 1)]:
        v[m.fx(name)] = val
    v[m.KEEP1] = v[m.KEEP1 + 1] = 1
    v[m.PAD_BASE] = 24 / 112
    v[m.MASTER] = 0.8
    v[m.DELAY_SYNC] = 1
    v[m.DELAY_TO] = 0.5
    for s, name in enumerate(["DRUMS", "BASS", "SKANK", "VOCALS", "SIREN", "SYNDRUM"]):
        t[m.NAME1 + s] = name
    titles = ["Roots Steppa", "Midnight Version", "Zion Gate Dub", "Rockers Rise", "Ammunition", "Sponji Reggae",
              "Don't Feel No Way", "Marchin", "Lift Up Your Heads", "Leggo Your Ego", "Wanted", "Gratitude",
              "Old Marcus Garvey", "Night Nurse"]
    states = [2, 2, 3, 4] + [1] * 10
    for i, (title, state) in enumerate(zip(titles, states)):
        t[m.SLOT_TITLE1 + i] = "%02d   %s" % (i + 1, title)
        v[m.SLOT1 + i] = state / 6
    t[m.PLAYING] = "Zion Gate Dub"
    t[m.NEXT] = "Rockers Rise"
    t[m.TIME_LEFT] = "-2:41"
    t[m.LIST_PAGE] = "1 / 1"
    for s in range(6):
        t[m.fader(s)] = "%.1f dB" % (20 * math.log10(v[m.fader(s)] ** 2.5))
    for name, text in [("delayTime", "1/4"), ("delayFeedback", "67 %"), ("reverbDecay", "70 %"), ("phaserRate", "0.30 Hz"),
                       ("delayToReverb", "-21 dB"), ("reverbSend", "-inf dB"), ("delayReturn", "-0.9 dB"),
                       ("reverbReturn", "-1.4 dB"), ("sirenPitch", "474 Hz"), ("sirenRate", "1.58 Hz"), ("sirenDelay", "50 %"),
                       ("syndrumPitch", "310 Hz"), ("syndrumDecay", "346 ms"), ("syndrumDelay", "50 %")]:
        t[m.fx(name)] = text
    t[m.PAD_BASE] = "24"
    t[m.MASTER] = "-4.8 dB"
    return v, t


def render(tab, values, texts, path):
    tui = json.load(open(os.path.join(SKIN, "TUI.json")))["pageData"]
    defs = {d["key"]: d["value"] for d in tui["componentDefinitions"]["localComponentDefinitions"]}
    img = Image.new("RGBA", (1280, 628), art.BG + (255,))
    d = ImageDraw.Draw(img, "RGBA")
    fonts = {}

    def font(h, bold):
        key = (int(h), bold)
        if key not in fonts:
            fonts[key] = ImageFont.truetype(os.path.join(art.FONTS, "Archivo-Variable.ttf"), int(h * 0.8))
            fonts[key].set_variation_by_axes([820 if bold else 520, 104])
        return fonts[key]

    def colour(c):
        n = int(c, 16)
        return ((n >> 16) & 255, (n >> 8) & 255, n & 255, (n >> 24) & 255)

    def png(name):
        return Image.open(os.path.join(SKIN, name)).convert("RGBA")

    def value(p):
        return values.get(p, 0)

    def visible(conditions):
        for h in conditions or []:
            mi = re.match(r"IndexedEnabling/(\d+)/(\d+)/Parameter (\d+)", h)
            if mi:
                i, n, p = map(int, mi.groups())
                if round(value(p) * (n - 1)) != i:
                    return False
                continue
            lo, hi, n, p = map(int, re.match(r"RangedEnabling/(\d+)/(\d+)/(\d+)/Parameter (\d+)", h).groups())
            if not lo <= round(value(p) * (n - 1)) <= hi:
                return False
        return True

    def draw(entries, ox, oy, param=None):
        for e in entries:
            b = e["bounds"]
            if not visible(b.get("additionalInvalidatingHandles")):
                continue
            x, y, w, h = map(float, b["bounds"].split())
            x, y = x + ox, y + oy
            kind, data = e["componentData"]["type"], e["componentData"]["data"]
            remap = e["handle remapping"]["map"]
            p = int(remap[0]["value"].split()[1]) if remap else param
            if kind in defs:
                draw(defs[kind]["componentsData"], x, y, p)
            elif kind == "Label":
                style = data["textStyle"]
                text = data.get("text") if data["type"] == "Text" else texts.get(p, "%d %%" % round(100 * value(p)))
                if style.get("case") == "Upper Case":
                    text = text.upper()
                f = font(style["font"]["height"], style["font"]["style"] in ("Bold", "Black", "SemiBold"))
                tw = d.textlength(text, font=f)
                j = style["justification"]
                tx = x + (w - tw) / 2 if "horizontallyCentred" in j else (x + w - tw if "right" in j else x)
                d.text((tx, y + h / 2), text, font=f, fill=colour(style["colour"]), anchor="lm")
            elif kind == "Button":
                steps = max(data["numButtonsInGroup"], 2)
                lit = round(value(p) * (steps - 1)) == data["buttonId"]
                im = png(data["onImage"] if lit else data["offImage"])
                img.alpha_composite(im, (int(x + (w - im.width) / 2), int(y + (h - im.height) / 2)))
            elif kind == "Image":
                img.alpha_composite(png(data["image"]).resize((int(w), int(h)), Image.LANCZOS), (int(x), int(y)))
            elif kind == "Knob":
                strip = png(data["filmStrip"])
                n = data["numFrames"]
                fh = strip.height // n
                k = round(value(p) * (n - 1))
                img.alpha_composite(strip.crop((0, fh * k, strip.width, fh * (k + 1))).resize((int(w), int(h)), Image.LANCZOS), (int(x), int(y)))
            elif kind == "Slider" and data.get("sliderType") == "TrackAndThumb":
                if data.get("revealedImage"):
                    lit = png(data["revealedImage"]).resize((int(w), int(h)))
                    cut = int(h * (1 - value(p)))
                    img.alpha_composite(lit.crop((0, cut, int(w), int(h))), (int(x), int(y) + cut))
                thumb = png(data["thumbImage"])
                if thumb.width > 1:
                    img.alpha_composite(thumb, (int(x + (w - thumb.width) / 2), int(y + (h - thumb.height) * (1 - value(p)))))

    draw(tui["tabs"][tab]["componentDefinition"]["componentsData"], 0, 0)
    img.convert("RGB").save(path, optimize=True)


def pads(path):
    """The MPC's 16 pads (bank A) and what DubStemMix does with them (PRD § 16.2 ter)."""
    size, gap, pad = 4, 14, 150
    w = h = size * pad + (size + 1) * gap
    img, d = art.canvas(w, h, art.BG + (255,))
    labels = {9: ("DROP", "HOLD", art.RED), 10: ("CRASH", "SPRING", art.REVERB), 11: ("REWIND", "PULL-UP", art.BUS3),
              13: ("PREV", "CUE ABOVE", art.TEXT), 14: ("NEXT", "CUE BELOW", art.DELAY), 15: ("GO", "PLAY NEXT", art.DELAY),
              16: ("RESTART", "THIS SONG", art.TEXT), 1: ("TAPE STOP", "AVOID", art.TEXT2), 2: ("BANK RIGHT", "AVOID", art.TEXT2)}
    for n in range(1, 17):
        col, row = (n - 1) % 4, 3 - (n - 1) // 4   # pad 1 bottom left, as on the MPC
        x, y = gap + col * (pad + gap), gap + row * (pad + gap)
        label = labels.get(n)
        active = label is not None and label[1] != "AVOID"
        box = [x * art.SS, y * art.SS, (x + pad) * art.SS, (y + pad) * art.SS]
        d.rounded_rectangle(box, radius=10 * art.SS, fill=art.SURFACE,
                            outline=art.mix(art.BORDER, label[2], 0.6) if active else art.BORDER, width=2 * art.SS)
        art.text(d, ((x + 14) * art.SS, (y + 18) * art.SS), str(n), art.label_font(14, 800), art.TEXT2, anchor="lm")
        if label:
            art.text(d, ((x + pad / 2) * art.SS, (y + pad / 2) * art.SS), label[0], art.label_font(19 if len(label[0]) < 8 else 15, 850),
                     label[2], tracking=1)
            art.text(d, ((x + pad / 2) * art.SS, (y + pad / 2 + 28) * art.SS), label[1], art.label_font(10, 800), art.TEXT2, tracking=1)
    img.resize((w, h), Image.LANCZOS).convert("RGB").save(path, optimize=True)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out, exist_ok=True)
    values, texts = demo()
    render(0, values, texts, os.path.join(out, "mpc-console.png"))
    fx = dict(values)
    fx[m.PAGE] = 1 / 3
    fx_texts = dict(texts)
    for name, text in [("delayWow", "25 %"), ("delayLowCut", "141 Hz"), ("delayHighCut", "2.7 kHz"), ("reverbDamping", "40 %"),
                       ("reverbPredelay", "20 ms"), ("reverbLowCut", "152 Hz"), ("reverbTone", "5.6 kHz"), ("phaserDepth", "75 %"),
                       ("phaserFeedback", "74 %"), ("phaserCenter", "632 Hz"), ("phaserStereo", "50 %"), ("phaserReturn", "+0 dB"),
                       ("delayToReverb", "-21 dB"), ("bus3Send", "-inf dB")]:
        fx_texts[m.fx(name)] = text
    render(0, fx, fx_texts, os.path.join(out, "mpc-fx.png"))
    render(2, values, texts, os.path.join(out, "mpc-song.png"))
    render(1, values, texts, os.path.join(out, "mpc-setup.png"))
    pads(os.path.join(out, "mpc-pads.png"))
    print("preview_skin.py: wrote 5 images in %s" % out)


if __name__ == "__main__":
    main()
