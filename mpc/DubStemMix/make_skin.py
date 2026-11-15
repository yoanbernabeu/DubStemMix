#!/usr/bin/env python3
"""Writes the plugin's MPC screen (skins/TUI.json, skins/Q-Links.json and the images), PRD § 16.2 bis / ter.

CONSOLE: a mirror of the MIDImix - 8 strips (name, 3 knobs, fader, meter, the buttons' lamps, SOLO and KEEP),
the knobs showing what they drive on the current console page (MIX, FX, MASTER, INSERTS), strips 5-6
following stem / instrument. SETUP: the settings as cards of buttons. SONG: the live setlist. TEST: readouts.
Every tab has the same header (logo, song, time left, next song, console page) and the Mac app's look
(skin_art.py draws the fixed parts with the app's fonts).

Parameter indices mirror the enum in src/DubStemMix.cpp; the script checks them against build/params.json.
Usage: python3 make_skin.py   (after a native build, which writes build/params.json)
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import skin_art as art  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))

# --- parameter indices (src/DubStemMix.cpp, src/FX.h) --------------------------------------------------------
FX = ["delayTime", "delayFeedback", "delayWow", "delayLowCut", "delayHighCut", "delayToReverb",
      "reverbDecay", "reverbDamping", "reverbPredelay", "reverbLowCut", "reverbTone",
      "phaserRate", "phaserDepth", "phaserFeedback", "phaserCenter", "phaserStereo",
      "delayReturn", "reverbReturn", "phaserReturn", "reverbSend", "bus3Send",
      "sirenPitch", "sirenRate", "sirenWave", "sirenDelay", "sirenReverb", "sirenBus3",
      "syndrumPitch", "syndrumDecay", "syndrumRoll", "syndrumDelay", "syndrumReverb", "syndrumBus3"]
FX2 = ["masterHighPass", "killBass", "killMid", "killTop", "dubplate", "crackle", "delayHeads", "delayPingPong"]
CAPTION = {"delayTime": "TIME", "delayFeedback": "FEEDBACK", "delayWow": "WOW", "delayLowCut": "LOW CUT",
           "delayHighCut": "HIGH CUT", "delayToReverb": "DLY>", "reverbDecay": "DECAY", "reverbDamping": "DAMPING",
           "reverbPredelay": "PREDELAY", "reverbLowCut": "LOW CUT", "reverbTone": "TONE", "phaserRate": "RATE",
           "phaserDepth": "DEPTH", "phaserFeedback": "RESONANCE", "phaserCenter": "CENTER", "phaserStereo": "STEREO",
           "delayReturn": "DLY RTN", "reverbReturn": "REV RTN", "phaserReturn": "PHS RTN", "reverbSend": "REV>",
           "bus3Send": "PHS>", "sirenPitch": "PITCH", "sirenRate": "RATE", "sirenDelay": "DLY",
           "syndrumPitch": "PITCH", "syndrumDecay": "DECAY", "syndrumDelay": "DLY",
           "masterHighPass": "BIG KNOB", "killBass": "BASS", "killMid": "MID", "killTop": "TOP",
           "dubplate": "DUBPLATE", "crackle": "CRACKLE", "delayHeads": "HEADS", "delayPingPong": "PING-PONG"}

STEMS, SURFACE_STRIPS, SLOTS, INSERT_KNOBS = 6, 8, 24, 3
MASTER = 0
def fader(s): return 1 + 5 * s
def mute(s): return 1 + 5 * s + 1
def send(s, b): return 1 + 5 * s + 2 + b
FX_BASE = 31
DELAY_SYNC = FX_BASE + len(FX)
REVERB_MODEL, BUS3_MODEL, THROW_TARGET, DELAY_TO, REVERB_TO, BUS3_TO = range(DELAY_SYNC + 1, DELAY_SYNC + 7)
PAGE = DELAY_SYNC + 7
NAME1 = PAGE + 1
MODE5, MODE6 = NAME1 + 6, NAME1 + 7
LAMP_MUTE1 = MODE6 + 1
LAMP_REC1 = LAMP_MUTE1 + 8
METER1 = LAMP_REC1 + 8
NEXT, PLAYING, STATE, TIME_LEFT, START, START_POS, LAST_CC, LAST_NOTE, CPU, UNDERRUNS = range(METER1 + 8, METER1 + 18)
SOLO1 = UNDERRUNS + 1
KEEP1 = SOLO1 + STEMS
FX2_BASE = KEEP1 + STEMS
INSERT1 = FX2_BASE + len(FX2)
INSERT_VALUE1 = INSERT1 + STEMS
PAD_BASE = INSERT_VALUE1 + STEMS * INSERT_KNOBS
CUE1 = PAD_BASE + 1
SLOT1 = CUE1 + SLOTS
def fx(name): return FX_BASE + FX.index(name) if name in FX else FX2_BASE + FX2.index(name)
def insert_value(s, i): return INSERT_VALUE1 + s * INSERT_KNOBS + i

FX_LAYOUT = [["delayTime", "delayFeedback", "delayWow"], ["delayLowCut", "delayHighCut", None],
             ["reverbDecay", "reverbDamping", "reverbPredelay"], ["reverbLowCut", "reverbTone", None],
             ["phaserRate", "phaserDepth", "phaserFeedback"], ["phaserCenter", "phaserStereo", None],
             ["delayReturn", "reverbReturn", "phaserReturn"], ["delayToReverb", "reverbSend", "bus3Send"]]
MASTER_LAYOUT = [["masterHighPass", None, None], ["killBass", "killMid", "killTop"], ["dubplate", "crackle", None],
                 ["delayHeads", "delayPingPong", None]] + [[None, None, None]] * 4
EFFECT_STRIPS = [["delayTime", "delayFeedback", "reverbDecay"], ["phaserRate", "delayToReverb", "reverbSend"]]
EFFECT_FADERS = ["delayReturn", "reverbReturn"]
INSTRUMENTS = [["sirenPitch", "sirenRate", "sirenDelay"], ["syndrumPitch", "syndrumDecay", "syndrumDelay"]]
INSERT_CAPTIONS = [[], ["AMOUNT", "CUTOFF"], ["SENS", "RANGE", "RESO"]]
PAGES = ["MIX", "FX", "MASTER", "INSERTS"]

# --- palette (PRD § 5.11, "reggae désaturé / terreux") -----------------------------------------------------------
BG, SURFACE, BORDER = "ff14110f", "ff1e1a17", "ff2e2823"
TEXT, TEXT2 = "ffede3cf", "ff9a8f7e"
DELAY, REVERB, BUS3, RED = "ffd9a441", "ff7e9b5a", "ffc2553a", "ffe5412d"
RGB = {TEXT: art.TEXT, TEXT2: art.TEXT2, DELAY: art.DELAY, REVERB: art.REVERB, BUS3: art.BUS3, RED: art.RED}
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
          font="Titillium Web", case="Original", kind="Value"):
    return entry("value", "Label", {"version": 1, "textStyle": style(height, colour, weight, justify, font, case), "type": kind,
                                    "handleName": "Data"}, rect, param, conditions)

def when(param, index, count):
    return "IndexedEnabling/%d/%d/Parameter %d" % (index, count, param)

def when_page(page):
    return when(PAGE, page, len(PAGES))

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
TOGGLE_ACTIONS = [{"version": 1, "onAction": "Mouse Down", "handler": "Toggle Switch", "handleName": "Data", "additionalData": ""}]

def focus(w, h):
    return {"version": 2, "componentData": {"version": 1, "name": "focus", "type": "Focus",
            "data": {"version": 1, "backgroundColour": "19ffffff", "outlineColour": TEXT, "backgroundInset": 2.0, "outlineThickness": 1.0}},
            "handle remapping": {"version": 1, "map": []},
            "bounds": {"version": 1, "acceptsHWFocus": "No", "showWhenDataModelInvalid": "Show", "whenVisible": "WhenFocussed",
                       "boundsType": "Absolute", "bounds": "0 0 %g %g" % (w, h)}}

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

KNOB_COLOURS = {TEXT: "knob_cream.png", DELAY: "knob_delay.png", REVERB: "knob_reverb.png", BUS3: "knob_bus3.png"}

def definitions():
    defs = json.load(open(os.path.join(HERE, "skin-base.json")))   # the SDK generator's slider slots
    out = [{"key": k, "value": v} for k, v in defs.items()]
    out.append(overlay("knob overlay", "KnobOverlay"))
    out.append(overlay("menu overlay", "MenuOverlay"))
    # The app's knob in each bus colour (the caption is in the card image).
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
    # A transparent area that flips its parameter when touched (a song of the list).
    out.append({"key": "touch", "value": component([], actions=TOGGLE_ACTIONS)})
    return out

def image(name, rect, conditions=None):
    return entry("image", "Image", {"version": 2, "imageType": "Regular", "colour": "0", "image": name}, rect, conditions=conditions)

def meter(param, rect):
    data = {"version": 4, "sliderType": "TrackAndThumb", "direction": "Vertical", "thumbImage": "blank.png",
            "thumbTrackVisible": False, "revealedImage": "meter_lit.png", "revealType": "Normal", "handleName": "Data"}
    return entry("meter", "Slider", data, rect, param)

def knob(param, colour, rect, conditions=None):
    return entry("knob", "knob " + colour, {"version": 1, "handleName": "Data"}, rect, param, conditions, focus="Yes")

def button(param, on_image, off_image, rect, step=1, steps=1, conditions=None):
    """An image button: a toggle (steps 1), or one choice of a radio group bound to a choice parameter."""
    data = {"version": 2, "onImage": on_image, "offImage": off_image, "buttonId": step, "numButtonsInGroup": steps,
            "handleName": "Data", "gestureBehaviour": "Instant"}
    return entry("button", "Button", data, rect, param, conditions, focus="Yes")

class Art:
    """Draws each image once, on first use."""
    def __init__(self, folder):
        self.folder, self.made = folder, set()

    def once(self, name, draw):
        if name not in self.made:
            draw(name)
            self.made.add(name)
        return name

    def card(self, name, number, accent, tint, captions):
        return self.once(name, lambda n: art.card(self.folder, n, number, RGB[accent], tint,
                                                  [(t, RGB[k]) if t else None for t, k in captions]))

    def button(self, title, lit, colour):
        name = "btn_%s_%s.png" % (title.lower().replace(" ", "_"), ("on_" + colour) if lit else "off")
        return self.once(name, lambda n: art.button(self.folder, n, title, lit, RGB[colour]))

    def pill(self, title, lit, colour, w, h, size=11):
        name = "pill_%s_%dx%d_%s.png" % (title.lower().replace(" ", "_").replace(">", "to").replace("-", "none"), w, h,
                                         ("on_" + colour) if lit else "off")
        return self.once(name, lambda n: art.pill(self.folder, n, title, lit, RGB[colour], w, h, size))

    def name(self, title, colour):
        return self.once("name_%s.png" % title.lower(), lambda n: art.name_image(self.folder, n, title, RGB[colour]))

    def title(self, s, colour=TEXT2, size=13, w=300, h=24, align="l"):
        name = "title_%s_%s.png" % (s.lower().replace(" ", "_").replace(">", "to").replace("/", "_"), colour)
        return self.once(name, lambda n: art.title(self.folder, n, s, RGB[colour], size, w, h, align))

    def panel(self, w, h, accent=None):
        return self.once("panel_%dx%d_%s.png" % (w, h, accent or "plain"),
                         lambda n: art.panel_card(self.folder, n, w, h, RGB[accent] if accent else None))

    def row(self, state):
        return self.once("row_%s.png" % state, lambda n: art.song_row(self.folder, n, state))

def draw_common(folder):
    for colour, strip in KNOB_COLOURS.items():
        art.knob_strip(folder, strip, RGB[colour])
    art.fader_cap(folder)
    art.meter_lit(folder)
    art.blank(folder)
    art.logo(folder)

# --- header, the same on every tab ------------------------------------------------------------------------------
PAGE_PILLS = [(1000, 52), (1056, 40), (1100, 76), (1180, 88)]   # x, width of MIX, FX, MASTER, INSERTS

def header(a):
    c = [image("logo.png", (12, 3, 230, 36))]
    c.append(value(PLAYING, (252, 0, 360, 40), 23, TEXT, "Black", "left verticallyCentred", font="Nexa", case="Upper Case"))
    c.append(value(TIME_LEFT, (612, 0, 84, 40), 20, TEXT2, "Regular", "right verticallyCentred", font="Roboto"))
    c.append(image(a.title("NEXT", TEXT2, 12, 46, 40), (712, 0, 46, 40)))
    c.append(value(NEXT, (766, 0, 228, 40), 16, TEXT2, "Regular", "left verticallyCentred", font="Roboto"))
    for i, page in enumerate(PAGES):
        x, w = PAGE_PILLS[i]
        rect = (x, 6, w, 28)
        c.append(image(a.pill(page, True, TEXT, w, 28, 12), rect, [when_page(i)]))
        for j in range(len(PAGES)):
            if j != i:
                c.append(image(a.pill(page, False, TEXT, w, 28, 12), rect, [when_page(j)]))
    return c

# --- the CONSOLE tab --------------------------------------------------------------------------------------------
def strip_x(s):
    return 8 + s * 156 + (16 if s >= 6 else 0)

CARD_Y = 44
PILLS_Y = CARD_Y + 294   # SOLO / KEEP, or the insert choice on the INSERTS page

def console(a):
    c = header(a)
    send_caps = [("DLY", DELAY), ("REV", REVERB), ("PHS", BUS3)]
    for s in range(SURFACE_STRIPS):
        x = strip_x(s)
        effect = s >= 6
        accent = [DELAY, REVERB][s - 6] if effect else TEXT
        number = (str(s + 1), ["DELAY", "SPACE"][s - 6] if effect else "")
        mode = MODE5 if s == 4 else MODE6 if s == 5 else None

        def put_card(name, captions, conditions, num=number):
            c.append(image(a.card(name, num, accent, effect, captions), (x, CARD_Y, art.CARD_W, art.CARD_H), conditions))

        def caps(names):
            return [(CAPTION[n], colour_of(n)) if n else (None, None) for n in names]

        # Cards: one per page (and per stem / instrument, per insert), with the knob captions.
        if s < 4:
            put_card("card%d_mix.png" % s, send_caps, [when_page(0)])
        elif s < 6:
            put_card("card%d_mix.png" % s, send_caps, [when_page(0), when(mode, 0, 2)])
            put_card("card%d_inst.png" % s, caps(INSTRUMENTS[s - 4]), [when_page(0), when(mode, 1, 2)],
                     num=(str(s + 1), ["SIREN", "SYNDRUM"][s - 4]))
        else:
            put_card("card%d_mix.png" % s, caps(EFFECT_STRIPS[s - 6]), [when_page(0)])
        put_card("card%d_fx.png" % s, caps(FX_LAYOUT[s]), [when_page(1)])
        put_card("card%d_master.png" % s, caps(MASTER_LAYOUT[s]), [when_page(2)])
        if s < STEMS:
            for kind in range(3):
                put_card("card%d_ins%d.png" % (s, kind), [(t, TEXT) for t in INSERT_CAPTIONS[kind]] + [(None, None)] * (3 - len(INSERT_CAPTIONS[kind])),
                         [when_page(3), when(INSERT1 + s, kind, 3)])
        else:
            put_card("card%d_ins.png" % s, caps([None, None, None]), [when_page(3)])

        # Knobs and values: what they drive on each page.
        for row in range(3):
            y = CARD_Y + art.KNOB_Y[row]
            def put(target, colour, conditions):
                param = fx(target) if isinstance(target, str) else target
                c.append(knob(param, colour if colour in KNOB_COLOURS else TEXT, (x + 41, y - 4, art.KNOB + 8, art.KNOB + 8), conditions))
                c.append(value(param, (x, y + art.CAPTION_DY + 11, art.CARD_W, 17), 14, TEXT2, "Regular", font="Roboto",
                               conditions=conditions))
            if s < 4:
                put(send(s, row), [DELAY, REVERB, BUS3][row], [when_page(0)])
            elif s < 6:
                put(send(s, row), [DELAY, REVERB, BUS3][row], [when_page(0), when(mode, 0, 2)])
                n = INSTRUMENTS[s - 4][row]
                put(n, colour_of(n), [when_page(0), when(mode, 1, 2)])
            else:
                n = EFFECT_STRIPS[s - 6][row]
                put(n, colour_of(n), [when_page(0)])
            for page, layout in ((1, FX_LAYOUT), (2, MASTER_LAYOUT)):
                n = layout[s][row]
                if n:
                    put(n, colour_of(n), [when_page(page)])
            if s < STEMS:
                for kind in (1, 2):
                    if row < len(INSERT_CAPTIONS[kind]):
                        put(insert_value(s, row), TEXT, [when_page(3), when(INSERT1 + s, kind, 3)])

        # SOLO and KEEP (an instrument always stays through DROP), or the insert choice on the INSERTS page.
        if s < STEMS:
            not_inserts = [when_page(p) for p in (0, 1, 2)]
            for page_condition in not_inserts:
                c.append(button(SOLO1 + s, a.pill("SOLO", True, TEXT, 64, 20, 10), a.pill("SOLO", False, TEXT, 64, 20, 10),
                                (x + 7, PILLS_Y, 64, 20), conditions=[page_condition]))
                keep_cond = [page_condition] + ([when(mode, 0, 2)] if mode else [])
                c.append(button(KEEP1 + s, a.pill("KEEP", True, TEXT, 64, 20, 10), a.pill("KEEP", False, TEXT, 64, 20, 10),
                                (x + 79, PILLS_Y, 64, 20), conditions=keep_cond))
            for kind, label in enumerate(("NONE", "SUB", "WAH")):
                c.append(button(INSERT1 + s, a.pill(label, True, TEXT, 44, 20, 10), a.pill(label, False, TEXT, 44, 20, 10),
                                (x + 5 + kind * 47, PILLS_Y, 44, 20), step=kind, steps=3, conditions=[when_page(3)]))

        # Name.
        name_rect = (x, CARD_Y + art.NAME_Y - 15, art.CARD_W, 30)
        if s < 4:
            c.append(value(NAME1 + s, name_rect, 21, TEXT, "Black", font="Nexa", case="Upper Case"))
        elif s < 6:
            c.append(value(NAME1 + s, name_rect, 21, TEXT, "Black", font="Nexa", case="Upper Case", conditions=[when(mode, 0, 2)]))
            c.append(image(a.name(["SIREN", "SYNDRUM"][s - 4], RED), name_rect, [when(mode, 1, 2)]))
        else:
            c.append(image(a.name(["DELAY", "SPACE"][s - 6], accent), name_rect))

        # Buttons, lit as the console's LEDs would be.
        def lamp(param, row, title, colour, conditions=None):
            rect = (x + 10, CARD_Y + art.BUTTON_Y[row], art.BUTTON[0], art.BUTTON[1])
            cond = conditions or []
            c.append(image(a.button(title, False, colour), rect, cond + [when(param, 0, 2)]))
            c.append(image(a.button(title, True, colour), rect, cond + [when(param, 1, 2)]))
        if s < 4:
            lamp(LAMP_MUTE1 + s, 0, "MUTE", TEXT)
            lamp(LAMP_REC1 + s, 1, "THROW", DELAY)
        elif s < 6:
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

# --- SETUP ------------------------------------------------------------------------------------------------------
SETUP_CHOICES = {DELAY_SYNC: ["OFF", "ON"], REVERB_MODEL: ["PLATE", "SPRING"], BUS3_MODEL: ["PHASER", "FLANGER"],
                 THROW_TARGET: ["DELAY", "REVERB", "BOTH"], DELAY_TO: ["-", "REV", "PHS"], REVERB_TO: ["-", "DLY", "PHS"],
                 BUS3_TO: ["-", "DLY", "REV"]}

def choice_row(a, c, param, label, x, y, colour, w=290):
    """A caption, then one pill per choice of a choice parameter (a radio group)."""
    options = SETUP_CHOICES[param]
    c.append(image(a.title(label, TEXT2, 11, w, 20), (x, y, w, 20)))
    pw = min(90, (w - 6 * (len(options) - 1)) // len(options))
    for k, option in enumerate(options):
        c.append(button(param, a.pill(option, True, colour, pw, 30, 12), a.pill(option, False, colour, pw, 30, 12),
                        (x + k * (pw + 6), y + 22, pw, 30), step=k, steps=len(options)))

def setup(a):
    c = header(a)
    top, bottom = 48, 206   # two rows of cards
    cards = [  # x, y, w, h, title, accent
        (8, top, 306, 150, "DELAY", DELAY), (322, top, 306, 150, "REVERB", REVERB), (636, top, 306, 150, "BUS 3", BUS3),
        (950, top, 322, 150, "THROW", DELAY), (8, bottom, 620, 416, "PADS", TEXT), (636, bottom, 306, 416, "MASTER", TEXT),
        (950, bottom, 322, 416, "SENDS BETWEEN BUSES", TEXT)]
    for x, y, w, h, t, accent in cards:
        c.append(image(a.panel(w, h, accent), (x, y, w, h)))
        c.append(image(a.title(t, accent, 14, w - 30, 24), (x + 22, y + 10, w - 30, 24)))
    choice_row(a, c, DELAY_SYNC, "TIME FOLLOWS THE MPC TEMPO", 30, top + 52, DELAY)
    choice_row(a, c, REVERB_MODEL, "MODEL", 344, top + 52, REVERB)
    choice_row(a, c, BUS3_MODEL, "EFFECT", 658, top + 52, BUS3)
    choice_row(a, c, THROW_TARGET, "REC ARM THROWS TO", 972, top + 52, DELAY)
    for i, (param, label, colour) in enumerate(((DELAY_TO, "DLY> SENDS TO", DELAY), (REVERB_TO, "REV> SENDS TO", REVERB),
                                                (BUS3_TO, "PHS> SENDS TO", BUS3))):
        choice_row(a, c, param, label, 972, bottom + 60 + i * 90, colour)
    c.append(image(a.title("THE KNOBS DLY> AND REV> ARE ON STRIP 8", TEXT2, 9, 280, 20), (972, bottom + 340, 280, 20)))
    # Master volume, as a knob.
    c.append(knob(MASTER, TEXT, (758, bottom + 120, art.KNOB + 8, art.KNOB + 8)))
    c.append(value(MASTER, (636, bottom + 194, 306, 22), 17, TEXT2, font="Roboto"))
    c.append(image(a.title("ALSO THE MIDIMIX MASTER FADER", TEXT2, 10, 280, 20, "m"), (649, bottom + 222, 280, 20)))
    # Pads: their note, and what each one does (pads 1-4 on the bottom row, as on the MPC).
    c.append(image(a.title("PAD 1 NOTE", TEXT2, 11, 140, 20), (30, bottom + 60, 140, 20)))
    c.append(knob(PAD_BASE, TEXT, (36, bottom + 86, art.KNOB + 8, art.KNOB + 8)))
    c.append(value(PAD_BASE, (16, bottom + 158, 110, 22), 17, TEXT2, font="Roboto"))
    c.append(image(a.title("CHECK ON TEST", TEXT2, 9, 120, 20, "m"), (11, bottom + 186, 120, 20)))
    pads = [(1, "DROP", RED, "HOLD"), (2, "CRASH", REVERB, "SPRING"), (3, "REWIND", BUS3, "PULL-UP"), (4, "-", TEXT2, ""),
            (5, "PREV", TEXT, "CUE THE ONE ABOVE"), (6, "NEXT", DELAY, "CUE THE ONE BELOW"), (7, "GO", DELAY, "PLAY NEXT"), (8, "RESTART", TEXT, "THIS SONG")]
    for i, (n, label, colour, hint) in enumerate(pads):
        col, row = i % 4, 1 - i // 4
        x, y = 160 + col * 114, bottom + 50 + row * 180
        c.append(image(a.panel(106, 170), (x, y, 106, 170)))
        c.append(image(a.title(str(n), TEXT2, 12, 98, 22, "m"), (x + 4, y + 10, 98, 22)))
        c.append(image(a.title(label, colour, 14, 98, 30, "m"), (x + 4, y + 62, 98, 30)))
        if hint:
            c.append(image(a.title(hint, TEXT2, 8, 98, 20, "m"), (x + 4, y + 100, 98, 20)))
    return c

# --- SONG: the live setlist -------------------------------------------------------------------------------------
ROW_STATES = ["plain", "played", "current", "next", "played-next", "current-next"]   # slot values 1..6

def songs(a):
    c = header(a)
    for i in range(SLOTS):
        col, row = i // 12, i % 12
        x, y = 16 + col * 640, 50 + row * 48
        slot = SLOT1 + i
        for k, state in enumerate(ROW_STATES):
            c.append(image(a.row(state), (x, y, art.ROW_W, art.ROW_H), [when(slot, k + 1, 7)]))
        # Number and title: dark on the cream block of the song playing, dimmed once played.
        for states, colour in (((1, 4), TEXT), ((2, 5), TEXT2), ((3, 6), BG)):
            for k in states:
                cond = [when(slot, k, 7)]
                c.append(text("%02d" % (i + 1), (x + 28, y, 40, art.ROW_H), 16, colour, "Bold", font="Roboto", conditions=cond))
                c.append(value(CUE1 + i, (x + 72, y, 440, art.ROW_H), 19, colour, "Bold", "left verticallyCentred",
                               conditions=cond, font="Nexa", kind="Name"))
        # Touching the line cues the song (the plugin sets it as next and lets the cue go).
        c.append(entry("cue", "touch", {"version": 1, "handleName": "Data"}, (x, y, art.ROW_W, art.ROW_H), CUE1 + i,
                       conditions=["RangedEnabling/1/6/7/Parameter %d" % slot]))
    return c

# --- TEST -------------------------------------------------------------------------------------------------------
def test(a):
    c = header(a)
    readouts = [("LAST CC", LAST_CC, "fader 1 = CC 19"), ("LAST NOTE", LAST_NOTE, "MUTE 1 = 1 · pad 1 = PAD 1 NOTE"),
                ("LAST START", START, "PLAY or PLAY START"), ("START POSITION", START_POS, "in beats"),
                ("CPU", CPU, "this plugin, % of the audio time"), ("UNDERRUNS", UNDERRUNS, "the card did not keep up")]
    for i, (t, param, hint) in enumerate(readouts):
        x, y = 8 + (i % 3) * 422, 48 + (i // 3) * 288
        c.append(image(a.panel(414, 280), (x, y, 414, 280)))
        c.append(image(a.title(t, TEXT2, 14, 380, 24), (x + 22, y + 14, 380, 24)))
        c.append(value(param, (x, y + 80, 414, 90), 56, TEXT, "Black", font="Nexa"))
        c.append(image(a.title(hint, TEXT2, 10, 380, 24, "m"), (x + 17, y + 220, 380, 24)))
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
    draw_common(out)
    a = Art(out)

    params = json.load(open(os.path.join(HERE, "build", "params.json")))["params"]
    names = [p["name"] for p in params]
    checks = {MASTER: "Master", fader(0): "Fader 1", send(5, 2): "PHS 6", fx("delayTime"): "Dly Time",
              fx("syndrumBus3"): "Syn PHS", DELAY_SYNC: "Delay sync", BUS3_TO: "PHS> to", PAGE: "Page",
              NAME1: "Name 1", MODE6: "Strip 6", LAMP_MUTE1: "Lamp M1", LAMP_REC1: "Lamp R1", METER1: "Meter 1",
              NEXT: "Next", UNDERRUNS: "Underruns", SOLO1: "Solo 1", KEEP1: "Keep 1", fx("masterHighPass"): "Big Knob",
              fx("delayPingPong"): "Dly PingPong", INSERT1: "Insert 1", insert_value(5, 2): "Insert 6C",
              PAD_BASE: "Pad 1 note", SLOT1: "Slot 1", SLOT1 + SLOTS - 1: "Slot %d" % SLOTS}
    for index, name in checks.items():
        if index >= len(names) or names[index] != name:
            sys.exit("make_skin.py: parameter %d is %r, expected %r - update the indices"
                     % (index, names[index] if index < len(names) else None, name))
    if len(names) != SLOT1 + SLOTS:
        sys.exit("make_skin.py: the plugin has %d parameters, expected %d" % (len(names), SLOT1 + SLOTS))

    replacements = dict(SETUP_CHOICES)
    for s in range(STEMS):
        replacements[INSERT1 + s] = ["None", "Sub", "Auto-wah"]
    tui = {"pageData": {
        "version": 1,
        "componentDefinitions": {"version": 2, "importFiles": [], "localComponentDefinitions": definitions()},
        "replacementStrings": [{"key": "Parameter %d" % k, "value": v} for k, v in replacements.items()],
        "info": {"version": 1, "type": "CompleteDescription"},
        "tabs": [tab("CONSOLE", 0, console(a)), tab("SETUP", 1, setup(a)), tab("SONG", 2, songs(a)), tab("TEST", 3, test(a))]}}

    def qmap(column):   # the first column of four goes to Q-Links 13, 9, 5, 1 (one-column MPCs bank here first)
        q = {"Q-Link %d" % i: -1 for i in range(1, 17)}
        for i, p in enumerate(column):
            q["Q-Link %d" % (13 - 4 * i)] = p
        return q
    console_knobs = [MASTER, fx("delayReturn"), fx("reverbReturn"), fx("delayTime")]
    qlinks = {"version": 4, "info": {"version": 1, "type": "CompleteDescription"},
              "Screen Mode Q-Links": {"version": 4, "map": [
                  {"Tab": 1, "SubTab": 1, "Bank Direction": "Column", "Q-Links": qmap(console_knobs)},
                  {"Tab": 2, "SubTab": 1, "Bank Direction": "Column", "Q-Links": qmap([MASTER, PAD_BASE])},
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
    print("make_skin.py: wrote skins/TUI.json, skins/Q-Links.json and %d images" % len(os.listdir(out)))

if __name__ == "__main__":
    main()
