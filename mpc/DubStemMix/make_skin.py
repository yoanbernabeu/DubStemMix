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

def style(height, colour, weight="Regular", justify="horizontallyCentred verticallyCentred"):
    return {"version": 1, "font": {"version": 1, "name": "Titillium Web", "style": weight, "height": float(height)},
            "colour": colour, "justification": justify, "case": "Original"}

def text(t, rect, height, colour, weight="Regular", justify="horizontallyCentred verticallyCentred", conditions=None):
    return entry("text", "Label", {"version": 1, "textStyle": style(height, colour, weight, justify), "type": "Text",
                                   "handleName": "Invalid", "text": t}, rect, conditions=conditions)

def value(param, rect, height, colour, weight="Regular", justify="horizontallyCentred verticallyCentred", conditions=None):
    return entry("value", "Label", {"version": 1, "textStyle": style(height, colour, weight, justify), "type": "Value",
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

KNOB_W, KNOB_H = 150, 70
FADER_W, FADER_H = 48, 170

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

def definitions():
    defs = json.load(open(os.path.join(HERE, "skin-base.json")))   # the SDK generator's slider slots
    out = [{"key": k, "value": v} for k, v in defs.items()]
    out.append(overlay("knob overlay", "KnobOverlay"))
    out.append(overlay("menu overlay", "MenuOverlay"))
    # A small knob with its value under it.
    out.append({"key": "miniKnob", "value": component([
        focus(KNOB_W, KNOB_H),
        {"version": 2, "componentData": {"version": 1, "name": "knob", "type": "Knob",
         "data": {"version": 5, "knobType": "GenericNoLabel", "polarity": "UniPolar", "dragOrientation": "Vertical", "handleName": "Data"}},
         "handle remapping": {"version": 1, "map": []}, "bounds": bounds(47, 0, 56, 48)},
        {"version": 2, "componentData": {"version": 1, "name": "value", "type": "Label",
         "data": {"version": 1, "textStyle": style(17, TEXT2), "type": "Value", "handleName": "Data"}},
         "handle remapping": {"version": 1, "map": []}, "bounds": bounds(0, 48, KNOB_W, 22)},
    ], actions=EDIT_ACTIONS)})
    # Vertical faders in each colour, opening the big editor.
    for c in (TEXT, DELAY, REVERB):
        out.append({"key": "fader " + c, "value": component([
            focus(FADER_W, FADER_H),
            {"version": 2, "componentData": {"version": 1, "name": "bar", "type": "Slider",
             "data": {"version": 2, "sliderType": "ColourBar", "direction": "Vertical", "backgroundColour": BORDER,
                      "outlineColour": BORDER, "valueColour": c, "isBipolar": False, "handleName": "Data"}},
             "handle remapping": {"version": 1, "map": []}, "bounds": bounds(6, 6, FADER_W - 12, FADER_H - 12)},
        ], actions=EDIT_ACTIONS)})
    # Flat coloured panels that let touches through (strip backgrounds, lamps).
    for c in (SURFACE, BORDER, TEXT, DELAY, REVERB, "ff372b18", "ff272a1d"):
        out.append({"key": "panel " + c, "value": component([], background=c, ignore=True)})
    return out

# --- the CONSOLE tab --------------------------------------------------------------------------------------------
def strip_x(s):
    return 8 + s * 156 + (16 if s >= 6 else 0)

def console():
    c = []
    # Header: song, time left, next, console page.
    c.append(value(PLAYING, (16, 0, 560, 40), 26, TEXT, "SemiBold", "left verticallyCentred"))
    c.append(value(TIME_LEFT, (580, 0, 120, 40), 26, TEXT, "SemiBold", "right verticallyCentred"))
    c.append(text("NEXT", (730, 0, 60, 40), 18, TEXT2, "Regular", "right verticallyCentred"))
    c.append(value(NEXT, (796, 0, 330, 40), 20, TEXT2, "Regular", "left verticallyCentred"))
    c.append(value(PAGE, (1140, 2, 124, 36), 26, DELAY, "Bold", "horizontallyCentred verticallyCentred"))

    for s in range(8):
        x = strip_x(s)
        tint = SURFACE if s < 6 else ("ff372b18" if s == 6 else "ff272a1d")
        c.append(panel(tint, (x, 44, 150, 584)))
        # Name.
        if s < 6:
            c.append(value(NAME1 + s, (x, 46, 150, 32), 20, TEXT, "Bold"))
        else:
            c.append(text(["7 DELAY", "8 SPACE"][s - 6], (x, 46, 150, 32), 20, [DELAY, REVERB][s - 6], "Bold"))
        # Knobs: what they drive on each page.
        for row in range(3):
            y = 84 + row * 94
            def put(param_name_or_index, caption, colour, conditions):
                param = fx(param_name_or_index) if isinstance(param_name_or_index, str) else param_name_or_index
                c.append(text(caption, (x, y, 150, 20), 15, colour, "SemiBold", conditions=conditions))
                c.append(knob(param, (x, y + 20, KNOB_W, KNOB_H), conditions))
            # MIX page.
            if s < 4:
                put(send(s, row), ["DLY", "REV", "PHS"][row], BUS_COLOURS[row], [ON_MIX])
            elif s < 6:
                mode = MODE5 if s == 4 else MODE6
                put(send(s, row), ["DLY", "REV", "PHS"][row], BUS_COLOURS[row], [ON_MIX, when(mode, 0, 2)])
                name = INSTRUMENTS[s - 4][row]
                put(name, CAPTION[name], colour_of(name), [ON_MIX, when(mode, 1, 2)])
            else:
                name = EFFECT_STRIPS[s - 6][row]
                put(name, CAPTION[name], colour_of(name), [ON_MIX])
            # FX page.
            name = FX_LAYOUT[s][row]
            if name:
                put(name, CAPTION[name], colour_of(name), [ON_FX])
        # Fader and meter.
        fp = fader(s) if s < 6 else fx(EFFECT_FADERS[s - 6])
        fc = TEXT if s < 6 else [DELAY, REVERB][s - 6]
        c.append(bar(fp, (x + 34, 370, FADER_W, FADER_H), fc, True))
        c.append(bar(METER1 + s, (x + 92, 376, 14, FADER_H - 12), REVERB, False))
        c.append(value(fp, (x, 540, 150, 22), 16, TEXT2))
        # Lamps: MUTE (top) and REC ARM (bottom) buttons, lit as the console's LEDs would be.
        def lamp(param, rect, label, lit_colour, conditions=None):
            cond = conditions or []
            c.append(panel(BORDER, rect, cond + [when(param, 0, 2)]))
            c.append(panel(lit_colour, rect, cond + [when(param, 1, 2)]))
            c.append(text(label, rect, 15, TEXT2, "SemiBold", conditions=cond + [when(param, 0, 2)]))
            c.append(text(label, rect, 15, BG, "Bold", conditions=cond + [when(param, 1, 2)]))
        top, bottom = (x + 6, 566, 138, 26), (x + 6, 598, 138, 26)
        if s < 4:
            lamp(LAMP_MUTE1 + s, top, "MUTE", TEXT)
            lamp(LAMP_REC1 + s, bottom, "THROW", DELAY)
        elif s < 6:
            mode = MODE5 if s == 4 else MODE6
            lamp(LAMP_MUTE1 + s, top, "MUTE", TEXT, [when(mode, 0, 2)])
            lamp(LAMP_REC1 + s, bottom, "THROW", DELAY, [when(mode, 0, 2)])
            lamp(LAMP_MUTE1 + s, top, ["SIREN", "HIT"][s - 4], TEXT, [when(mode, 1, 2)])
            lamp(LAMP_REC1 + s, bottom, ["RISE", "ROLL"][s - 4], DELAY, [when(mode, 1, 2)])
        else:
            colour = [DELAY, REVERB][s - 6]
            lamp(LAMP_MUTE1 + s, top, ["HOLD", "FX ONLY"][s - 6], colour)
            lamp(LAMP_REC1 + s, bottom, ["x2", "TAPE STOP"][s - 6], colour)
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
            tab("CONSOLE", 0, console()),
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

    out = os.path.join(HERE, "skins")
    os.makedirs(out, exist_ok=True)
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
