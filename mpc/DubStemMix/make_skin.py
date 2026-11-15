#!/usr/bin/env python3
"""Writes the plugin's MPC screen (skins/TUI.json, skins/Q-Links.json), PRD § 16.2 bis.

CONSOLE: a mirror of the MIDImix - 8 strips (name, 3 knobs, fader, meter, the two buttons' lamps), the knobs
showing what they drive on the current console page (MIX or FX), strips 5-6 following stem / instrument.
SETUP, SONG and TEST: plain pages of the MPC's own sliders.

Parameter indices mirror the enum in src/DubStemMix.cpp; the script checks them against build/params.json.
Usage: python3 make_skin.py   (after a native build, which writes build/params.json)
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

HERE = os.path.dirname(os.path.abspath(__file__))

# --- parameter indices (src/DubStemMix.cpp, src/FX.h) --------------------------------------------------------
FX = ["delayTime", "delayFeedback", "delayWow", "delayLowCut", "delayHighCut", "delayToReverb",
      "reverbDecay", "reverbDamping", "reverbPredelay", "reverbLowCut", "reverbTone",
      "phaserRate", "phaserDepth", "phaserFeedback", "phaserCenter", "phaserStereo",
      "delayReturn", "reverbReturn", "phaserReturn", "reverbSend", "bus3Send",
      "sirenPitch", "sirenRate", "sirenWave", "sirenDelay", "sirenReverb", "sirenBus3",
      "syndrumPitch", "syndrumDecay", "syndrumRoll", "syndrumDelay", "syndrumReverb", "syndrumBus3"]
CAPTION = {"delayTime": "TIME", "delayFeedback": "FEEDBACK", "delayWow": "WOW", "delayLowCut": "LOW CUT",
           "delayHighCut": "HIGH CUT", "delayToReverb": "DLY>", "reverbDecay": "DECAY", "reverbDamping": "DAMPING",
           "reverbPredelay": "PREDELAY", "reverbLowCut": "LOW CUT", "reverbTone": "TONE", "phaserRate": "RATE",
           "phaserDepth": "DEPTH", "phaserFeedback": "RESONANCE", "phaserCenter": "CENTER", "phaserStereo": "STEREO",
           "delayReturn": "DLY RTN", "reverbReturn": "REV RTN", "phaserReturn": "PHS RTN", "reverbSend": "REV>",
           "bus3Send": "PHS>", "sirenPitch": "PITCH", "sirenRate": "RATE", "sirenDelay": "DLY",
           "syndrumPitch": "PITCH", "syndrumDecay": "DECAY", "syndrumDelay": "DLY"}

MASTER = 0
def fader(s): return 1 + 5 * s
def mute(s): return 1 + 5 * s + 1
def send(s, b): return 1 + 5 * s + 2 + b
FX_BASE = 31
def fx(name): return FX_BASE + FX.index(name)
DELAY_SYNC = FX_BASE + len(FX)
REVERB_MODEL, BUS3_MODEL, THROW_TARGET, DELAY_TO, REVERB_TO, BUS3_TO = range(DELAY_SYNC + 1, DELAY_SYNC + 7)
PAGE = DELAY_SYNC + 7
NAME1 = PAGE + 1
MODE5, MODE6 = NAME1 + 6, NAME1 + 7
LAMP_MUTE1 = MODE6 + 1
LAMP_REC1 = LAMP_MUTE1 + 8
METER1 = LAMP_REC1 + 8
NEXT, PLAYING, STATE, TIME_LEFT, START, START_POS, LAST_CC, LAST_NOTE, CPU, UNDERRUNS = range(METER1 + 8, METER1 + 18)

FX_LAYOUT = [["delayTime", "delayFeedback", "delayWow"], ["delayLowCut", "delayHighCut", None],
             ["reverbDecay", "reverbDamping", "reverbPredelay"], ["reverbLowCut", "reverbTone", None],
             ["phaserRate", "phaserDepth", "phaserFeedback"], ["phaserCenter", "phaserStereo", None],
             ["delayReturn", "reverbReturn", "phaserReturn"], ["delayToReverb", "reverbSend", "bus3Send"]]
EFFECT_STRIPS = [["delayTime", "delayFeedback", "reverbDecay"], ["phaserRate", "delayToReverb", "reverbSend"]]
EFFECT_FADERS = ["delayReturn", "reverbReturn"]
INSTRUMENTS = [["sirenPitch", "sirenRate", "sirenDelay"], ["syndrumPitch", "syndrumDecay", "syndrumDelay"]]

# --- palette (PRD § 9, "reggae désaturé / terreux") -------------------------------------------------------------
BG, SURFACE, BORDER = "ff14110f", "ff1e1a17", "ff2e2823"
TEXT, TEXT2 = "ffede3cf", "ff9a8f7e"
DELAY, REVERB, BUS3, RED = "ffd9a441", "ff7e9b5a", "ffc2553a", "ffe5412d"
BUS_COLOURS = [DELAY, REVERB, BUS3]
def colour_of(name):
    if name.startswith("delay") or name in ("sirenDelay", "syndrumDelay"): return DELAY
    if name.startswith("reverb"): return REVERB
    if name.startswith("phaser") or name == "bus3Send": return BUS3
    return TEXT

# --- JSON building blocks ---------------------------------------------------------------------------------------
def bounds(x, y, w, h, focus="No", conditions=None):
    b = {"version": 2 if conditions else 1, "acceptsHWFocus": focus, "showWhenDataModelInvalid": "Show",
         "whenVisible": "Always", "boundsType": "Absolute", "bounds": "%g %g %g %g" % (x, y, w, h)}
    if conditions:
        b["additionalInvalidatingHandles"] = conditions
    return b

def entry(name, kind, data, rect, param=None, conditions=None, focus="No"):
    return {"version": 2,
            "componentData": {"version": 1, "name": name, "type": kind, "data": data},
            "handle remapping": {"version": 1, "map": [{"key": "Data", "value": "Parameter %d" % param}] if param is not None else []},
            "bounds": bounds(*rect, focus=focus, conditions=conditions)}

def style(height, colour, weight="Regular", justify="horizontallyCentred verticallyCentred", font="Titillium Web", case="Original"):
    return {"version": 1, "font": {"version": 1, "name": font, "style": weight, "height": float(height)},
            "colour": colour, "justification": justify, "case": case}

def text(t, rect, height, colour, weight="Regular", justify="horizontallyCentred verticallyCentred", conditions=None,
         font="Titillium Web", case="Original"):
    return entry("text", "Label", {"version": 1, "textStyle": style(height, colour, weight, justify, font, case), "type": "Text",
                                   "handleName": "Invalid", "text": t}, rect, conditions=conditions)

def value(param, rect, height, colour, weight="Regular", justify="horizontallyCentred verticallyCentred", conditions=None,
          font="Titillium Web", case="Original"):
    return entry("value", "Label", {"version": 1, "textStyle": style(height, colour, weight, justify, font, case), "type": "Value",
                                    "handleName": "Data"}, rect, param, conditions)

def panel(colour, rect, conditions=None):
    return entry("panel", "panel " + colour, {"version": 1, "handleName": "Data"}, rect, conditions=conditions)

def bar(param, rect, colour, editable, conditions=None):
    data = {"version": 2, "sliderType": "ColourBar", "direction": "Vertical", "backgroundColour": BORDER,
            "outlineColour": BORDER, "valueColour": colour, "isBipolar": False, "handleName": "Data"}
    if editable:   # a fader: wrapped so it opens the big editor and grabs a Q-Link like any control
        return entry("fader", "fader " + colour, {"version": 1, "handleName": "Data"}, rect, param, conditions, focus="Yes")
    return entry("meter", "Slider", data, rect, param, conditions)

def knob(param, rect, conditions=None):
    return entry("knob", "miniKnob", {"version": 1, "handleName": "Data"}, rect, param, conditions, focus="Yes")

def when(param, index, count):
    return "IndexedEnabling/%d/%d/Parameter %d" % (index, count, param)

ON_MIX, ON_FX = when(PAGE, 0, 2), when(PAGE, 1, 2)

def component(children, background="0", ignore=False, actions=None):
    return {"version": 2, "actions": actions or [],
            "backgroundData": {"version": 1, "focussed": {"version": 1, "colour": background, "image": ""},
                               "unfocussed": {"version": 1, "colour": background, "image": ""}},
            "ignoreMousePresses": ignore, "disableCoarseDataWheel": False, "componentsData": children}

EDIT_ACTIONS = [
    {"version": 1, "onAction": "Mouse Down", "handler": "Q-Link", "handleName": "Data", "additionalData": ""},
    {"version": 1, "onAction": "Double Click", "handler": "Show Overlay", "handleName": "Data", "additionalData": "knob overlay"},
    {"version": 1, "onAction": "Enter Pressed", "handler": "Show Overlay", "handleName": "Data", "additionalData": "knob overlay"},
]
FOCUS = {"version": 2, "componentData": {"version": 1, "name": "focus", "type": "Focus",
         "data": {"version": 1, "backgroundColour": "19ffffff", "outlineColour": TEXT, "backgroundInset": 2.0, "outlineThickness": 1.0}},
         "handle remapping": {"version": 1, "map": []},
         "bounds": {"version": 1, "acceptsHWFocus": "No", "showWhenDataModelInvalid": "Show", "whenVisible": "WhenFocussed",
                    "boundsType": "Absolute", "bounds": "0 0 %g %g"}}

def focus(w, h):
    f = json.loads(json.dumps(FOCUS))
    f["bounds"]["bounds"] = "0 0 %g %g" % (w, h)
    return f

# The overlays carry two "version" keys in one object (ui-reference 1.8), which a JSON library cannot hold:
# they are written as text, in place of these markers.
OVERLAY_ACTIONS = '[{"version": 1, "onAction": "Focus Lost", "handler": "Focus Lost", "handleName": "Focus Lost", "additionalData": ""}]'
RAW = {
    "knob overlay": '{"version": 2, "version": 1, "actions": %s, "overlayType": "Knob With Header", "scaleType": "Linear", '
                    '"polarityType": "Unipolar", "showMinusSign": true, "handleName": "Data"}' % OVERLAY_ACTIONS,
    "menu overlay": '{"version": 1, "version": 1, "actions": %s, "withNumbers": false, "handleName": "Data"}' % OVERLAY_ACTIONS,
}

def overlay(name, kind):
    return {"key": name, "value": component([
        {"version": 2, "componentData": {"version": 1, "name": "overlay", "type": kind, "data": "@@RAW:%s@@" % name},
         "handle remapping": {"version": 1, "map": []},
         "bounds": {"version": 1, "acceptsHWFocus": "Yes", "showWhenDataModelInvalid": "Show", "whenVisible": "Always",
                    "boundsType": "Absolute", "bounds": "0 0 1280 800"}}], ignore=True)}


import skin_art as art

KNOB_COLOURS = {TEXT: "knob_cream.png", DELAY: "knob_delay.png", REVERB: "knob_reverb.png", BUS3: "knob_bus3.png"}
STRIP_COLOURS = {TEXT: art.TEXT, DELAY: art.DELAY, REVERB: art.REVERB, BUS3: art.BUS3, RED: art.RED}

def definitions():
    defs = json.load(open(os.path.join(HERE, "skin-base.json")))   # the SDK generator's slider slots
    out = [{"key": k, "value": v} for k, v in defs.items()]
    out.append(overlay("knob overlay", "KnobOverlay"))
    out.append(overlay("menu overlay", "MenuOverlay"))
    # The app's knob in each bus colour, its value under it (the caption is in the card image).
    for colour, strip in KNOB_COLOURS.items():
        out.append({"key": "knob " + colour, "value": component([
            focus(art.KNOB + 8, art.KNOB + 8),
            {"version": 2, "componentData": {"version": 1, "name": "knob", "type": "Knob",
             "data": {"version": 4, "knobType": "FilmStrip", "filmStrip": strip, "numFrames": art.KNOB_FRAMES,
                      "invert": False, "dragOrientation": "Vertical", "handleName": "Data"}},
             "handle remapping": {"version": 1, "map": []}, "bounds": bounds(4, 4, art.KNOB, art.KNOB)},
        ], actions=EDIT_ACTIONS)})
    # The app's fader: a cream cap sliding on the track drawn in the card image.
    out.append({"key": "fader", "value": component([
        focus(44, art.FADER_H),
        {"version": 2, "componentData": {"version": 1, "name": "cap", "type": "Slider",
         "data": {"version": 3, "sliderType": "TrackAndThumb", "direction": "Vertical", "thumbImage": "fader_cap.png",
                  "thumbTrackVisible": False, "revealedImage": "", "handleName": "Data"}},
         "handle remapping": {"version": 1, "map": []}, "bounds": bounds(4, 0, 36, art.FADER_H)},
    ], actions=EDIT_ACTIONS)})
    return out

def image(name, rect, conditions=None):
    return entry("image", "Image", {"version": 2, "imageType": "Regular", "colour": "0", "image": name}, rect, conditions=conditions)

def meter(param, rect):
    data = {"version": 4, "sliderType": "TrackAndThumb", "direction": "Vertical", "thumbImage": "blank.png",
            "thumbTrackVisible": False, "revealedImage": "meter_lit.png", "revealType": "Normal", "handleName": "Data"}
    return entry("meter", "Slider", data, rect, param)

def knob(param, colour, rect, conditions=None):
    return entry("knob", "knob " + colour, {"version": 1, "handleName": "Data"}, rect, param, conditions, focus="Yes")

def draw_art(folder):
    """Writes every image the screen uses into the skin folder."""
    for colour, strip in KNOB_COLOURS.items():
        art.knob_strip(folder, strip, STRIP_COLOURS[colour])
    art.fader_cap(folder)
    art.meter_lit(folder)
    art.blank(folder)
    art.logo(folder)
    for page in ("MIX", "FX"):
        for lit in (True, False):
            art.page_pill(folder, page, lit)

# --- the CONSOLE tab --------------------------------------------------------------------------------------------
def strip_x(s):
    return 8 + s * 156 + (16 if s >= 6 else 0)

CARD_Y = 44

def console(folder):
    c = []
    # Header: logo, song, time left, next, console page.
    c.append(image("logo.png", (12, 3, 230, 36)))
    c.append(value(PLAYING, (252, 0, 404, 40), 24, TEXT, "Black", "left verticallyCentred", font="Nexa", case="Upper Case"))
    c.append(value(TIME_LEFT, (660, 0, 100, 40), 22, TEXT2, "Regular", "right verticallyCentred", font="Roboto"))
    c.append(text("NEXT", (782, 0, 50, 40), 15, TEXT2, "Bold", "right verticallyCentred", font="Nexa"))
    c.append(value(NEXT, (840, 0, 290, 40), 17, TEXT2, "Regular", "left verticallyCentred", font="Roboto"))
    for i, page in enumerate(("MIX", "FX")):
        rect = (1134 + i * 70, 5, 64, 30)
        c.append(image("page_%s_on.png" % page.lower(), rect, [when(PAGE, i, 2)]))
        c.append(image("page_%s_off.png" % page.lower(), rect, [when(PAGE, 1 - i, 2)]))

    made = set()
    def card(name, number, accent, tint, captions):
        if name not in made:
            art.card(folder, name, number, STRIP_COLOURS[accent], tint, [(t, STRIP_COLOURS[k]) if t else None for t, k in captions])
            made.add(name)
        return name

    def button(title, lit, colour):
        name = "btn_%s_%s.png" % (title.lower().replace(" ", "_"), ("on_" + colour) if lit else "off")
        if name not in made:
            art.button(folder, name, title, lit, STRIP_COLOURS[colour])
            made.add(name)
        return name

    def name_image(title, colour):
        name = "name_%s.png" % title.lower()
        if name not in made:
            art.name_image(folder, name, title, STRIP_COLOURS[colour])
            made.add(name)
        return name

    for s in range(8):
        x = strip_x(s)
        effect = s >= 6
        accent = [DELAY, REVERB][s - 6] if effect else TEXT
        number = (str(s + 1), ["DELAY", "SPACE"][s - 6] if effect else "")
        fx_caps = [(CAPTION[n], colour_of(n)) if n else (None, None) for n in FX_LAYOUT[s]]

        # Cards: one per page (and, on strips 5-6, per stem / instrument), with the knob captions.
        def put_card(name, captions, conditions, num=number):
            c.append(image(card(name, num, accent, effect, captions), (x, CARD_Y, art.CARD_W, art.CARD_H), conditions))
        send_caps = [("DLY", DELAY), ("REV", REVERB), ("PHS", BUS3)]
        if s < 4:
            put_card("card%d_mix.png" % s, send_caps, [ON_MIX])
        elif s < 6:
            mode = MODE5 if s == 4 else MODE6
            put_card("card%d_mix.png" % s, send_caps, [ON_MIX, when(mode, 0, 2)])
            inst = [(CAPTION[n], colour_of(n)) for n in INSTRUMENTS[s - 4]]
            put_card("card%d_inst.png" % s, inst, [ON_MIX, when(mode, 1, 2)],
                     num=(str(s + 1), ["SIREN", "SYNDRUM"][s - 4]))
        else:
            put_card("card%d_mix.png" % s, [(CAPTION[n], colour_of(n)) for n in EFFECT_STRIPS[s - 6]], [ON_MIX])
        put_card("card%d_fx.png" % s, fx_caps, [ON_FX])

        # Knobs and values: what they drive on each page.
        for row in range(3):
            y = CARD_Y + art.KNOB_Y[row]
            def put(target, colour, conditions):
                param = fx(target) if isinstance(target, str) else target
                c.append(knob(param, KNOB_COLOURS.get(colour) and colour or TEXT, (x + 41, y - 4, art.KNOB + 8, art.KNOB + 8), conditions))
                c.append(value(param, (x, y + art.CAPTION_DY + 12, art.CARD_W, 18), 15, TEXT2, "Regular", font="Roboto",
                               conditions=conditions))
            if s < 4:
                put(send(s, row), [DELAY, REVERB, BUS3][row], [ON_MIX])
            elif s < 6:
                mode = MODE5 if s == 4 else MODE6
                put(send(s, row), [DELAY, REVERB, BUS3][row], [ON_MIX, when(mode, 0, 2)])
                n = INSTRUMENTS[s - 4][row]
                put(n, colour_of(n), [ON_MIX, when(mode, 1, 2)])
            else:
                n = EFFECT_STRIPS[s - 6][row]
                put(n, colour_of(n), [ON_MIX])
            n = FX_LAYOUT[s][row]
            if n:
                put(n, colour_of(n), [ON_FX])

        # Name.
        name_rect = (x, CARD_Y + art.NAME_Y - 15, art.CARD_W, 30)
        if s < 4:
            c.append(value(NAME1 + s, name_rect, 21, TEXT, "Black", font="Nexa", case="Upper Case"))
        elif s < 6:
            mode = MODE5 if s == 4 else MODE6
            c.append(value(NAME1 + s, name_rect, 21, TEXT, "Black", font="Nexa", case="Upper Case", conditions=[when(mode, 0, 2)]))
            c.append(image(name_image(["SIREN", "SYNDRUM"][s - 4], RED), name_rect, [when(mode, 1, 2)]))
        else:
            c.append(image(name_image(["DELAY", "SPACE"][s - 6], accent), name_rect))

        # Buttons, lit as the console's LEDs would be.
        def lamp(param, row, title, colour, conditions=None):
            rect = (x + 10, CARD_Y + art.BUTTON_Y[row], art.BUTTON[0], art.BUTTON[1])
            cond = conditions or []
            c.append(image(button(title, False, colour), rect, cond + [when(param, 0, 2)]))
            c.append(image(button(title, True, colour), rect, cond + [when(param, 1, 2)]))
        if s < 4:
            lamp(LAMP_MUTE1 + s, 0, "MUTE", TEXT)
            lamp(LAMP_REC1 + s, 1, "THROW", DELAY)
        elif s < 6:
            mode = MODE5 if s == 4 else MODE6
            lamp(LAMP_MUTE1 + s, 0, "MUTE", TEXT, [when(mode, 0, 2)])
            lamp(LAMP_REC1 + s, 1, "THROW", DELAY, [when(mode, 0, 2)])
            lamp(LAMP_MUTE1 + s, 0, ["HOLD", "HIT"][s - 4], [RED, TEXT][s - 4], [when(mode, 1, 2)])
            lamp(LAMP_REC1 + s, 1, ["RISE", "ROLL"][s - 4], DELAY, [when(mode, 1, 2)])
        else:
            lamp(LAMP_MUTE1 + s, 0, ["HOLD", "FX ONLY"][s - 6], accent)
            lamp(LAMP_REC1 + s, 1, ["x2", "TAPE STOP"][s - 6], accent)

        # Fader, meter and level.
        fp = fader(s) if s < 6 else fx(EFFECT_FADERS[s - 6])
        c.append(entry("fader", "fader", {"version": 1, "handleName": "Data"},
                       (x + art.FADER_X, CARD_Y + art.FADER_Y, 44, art.FADER_H), fp, focus="Yes"))
        c.append(meter(METER1 + s, (x + art.METER_X, CARD_Y + art.FADER_Y + 4, art.METER_W, art.FADER_H - 8)))
        c.append(value(fp, (x, CARD_Y + art.FADER_Y + art.FADER_H + 2, art.CARD_W, 18), 14, TEXT2, "Regular", font="Roboto"))
    return c

# --- plain pages ------------------------------------------------------------------------------------------------
GRID = [(23 + 320 * col, 45 + 151 * row) for row in range(4) for col in range(4)]

def plain(params_by_slot, menus=()):
    c = []
    for slot, p in enumerate(params_by_slot):
        if p is None:
            continue
        x, y = GRID[slot]
        kind = "sliderWithFocusMenu" if p in menus else "sliderWithFocus"
        c.append(entry("slot", kind, {"version": 1, "handleName": "Data"}, (x, y, 278, 107), p, focus="Yes"))
    return c

def tab(name, key, children):
    return {"version": 1, "tabName": name, "fnKeyIndex": key, "fnKeySubIndex": 0,
            "componentDefinition": component(children, background=BG), "qlinkBoundsData": []}

def main():
    out = os.path.join(HERE, "skins")
    if os.path.isdir(out):
        for f in os.listdir(out):
            if f.endswith(".png"):
                os.remove(os.path.join(out, f))   # images no longer used go away
    os.makedirs(out, exist_ok=True)
    draw_art(out)
    params = json.load(open(os.path.join(HERE, "build", "params.json")))["params"]
    names = [p["name"] for p in params]
    checks = {MASTER: "Master", fader(0): "Fader 1", send(5, 2): "PHS 6", fx("delayTime"): "Dly Time",
              fx("syndrumBus3"): "Syn PHS", DELAY_SYNC: "Delay sync", BUS3_TO: "PHS> to", PAGE: "Page",
              NAME1: "Name 1", MODE6: "Strip 6", LAMP_MUTE1: "Lamp M1", LAMP_REC1: "Lamp R1", METER1: "Meter 1",
              NEXT: "Next", UNDERRUNS: "Underruns"}
    for index, name in checks.items():
        if names[index] != name:
            sys.exit("make_skin.py: parameter %d is %r, expected %r - update the indices" % (index, names[index], name))

    choices = {DELAY_SYNC: ["Off", "On"], REVERB_MODEL: ["Plate", "Spring"], BUS3_MODEL: ["Phaser", "Flanger"],
               THROW_TARGET: ["Delay", "Reverb", "Both"], DELAY_TO: ["-", "REV", "PHS"], REVERB_TO: ["-", "DLY", "PHS"],
               BUS3_TO: ["-", "DLY", "REV"]}
    setup = [MASTER, DELAY_SYNC, REVERB_MODEL, BUS3_MODEL,
             THROW_TARGET, DELAY_TO, REVERB_TO, BUS3_TO]
    tui = {"pageData": {
        "version": 1,
        "componentDefinitions": {"version": 2, "importFiles": [], "localComponentDefinitions": definitions()},
        "replacementStrings": [{"key": "Parameter %d" % k, "value": v} for k, v in choices.items()],
        "info": {"version": 1, "type": "CompleteDescription"},
        "tabs": [
            tab("CONSOLE", 0, console(out)),
            tab("SETUP", 1, plain(setup, menus=set(choices))),
            tab("SONG", 2, plain([PLAYING, NEXT, STATE, TIME_LEFT])),
            tab("TEST", 3, plain([LAST_CC, LAST_NOTE, START, START_POS, CPU, UNDERRUNS])),
        ]}}

    def qmap(column):   # the first column of four goes to Q-Links 13, 9, 5, 1 (one-column MPCs bank here first)
        q = {"Q-Link %d" % i: -1 for i in range(1, 17)}
        for i, p in enumerate(column):
            q["Q-Link %d" % (13 - 4 * i)] = p
        return q
    console_knobs = [MASTER, fx("delayReturn"), fx("reverbReturn"), fx("delayTime")]
    qlinks = {"version": 4, "info": {"version": 1, "type": "CompleteDescription"},
              "Screen Mode Q-Links": {"version": 4, "map": [
                  {"Tab": 1, "SubTab": 1, "Bank Direction": "Column", "Q-Links": qmap(console_knobs)},
                  {"Tab": 2, "SubTab": 1, "Bank Direction": "Column", "Q-Links": qmap(setup[:4])},
                  {"Tab": 3, "SubTab": 1, "Bank Direction": "Column", "Q-Links": qmap([NEXT])},
                  {"Tab": 4, "SubTab": 1, "Bank Direction": "Column", "Q-Links": qmap([])},
              ]},
              "Program Mode Q-Links": {"Q-Link %d" % (i + 1): (console_knobs[i] if i < 4 else -1) for i in range(16)}}

    body = json.dumps(tui, indent=1)
    for name, raw in RAW.items():
        body = body.replace('"@@RAW:%s@@"' % name, raw)
    with open(os.path.join(out, "TUI.json"), "w") as f:
        f.write(body)
    with open(os.path.join(out, "Q-Links.json"), "w") as f:
        json.dump(qlinks, f, indent=1)
    print("make_skin.py: wrote skins/TUI.json and skins/Q-Links.json")

if __name__ == "__main__":
    main()
