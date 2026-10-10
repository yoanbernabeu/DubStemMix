---
title: Playing live
seoTitle: Play a dub set live with DubStemMix
description: "Chain the tunes of a setlist without a gap, take a request mid-set, see the end of the tune coming and play safe: DubStemMix on the sound system."
nav: Playing live
order: 8
---

On stage, nothing should cut the sound by accident, and the next tune should be one gesture away. Here is how a set runs.

## Before the set

- **Load the setlist** in the console (from the [workshop](../sets/), LOAD IN THE CONSOLE, or by opening the `.dubset` file).
- **Check the warnings.** When the setlist opens, and each time you come back to the app, it looks for every tune's stems and plugins. A tune with a problem is marked **⚠**; its tooltip says what is missing. A disk not plugged in? Plug it, come back to the app: the marks update.
- **Stems moved?** **LOCATE MISSING STEMS…** takes one folder for the whole setlist and finds the stems by name in it and its subfolders.
- **Set the buffer** to 128 or 256 samples in Settings for a tight response.
- **Press SEND ALL** on the console.

## Chain the tunes

While a tune plays:

1. **Arm the next one**: <kbd>N</kbd> (or <kbd>P</kbd> for the previous one, or a click on any line of the setlist). It blinks on the waveform. Nothing is cut, the tune plays on.
2. **Drop it**, when you are ready:
   - <kbd>Space</kbd>: the current tune stops dead, the armed one starts from the top. The effect tails keep ringing over the change.
   - <kbd>R</kbd>: **pull-up into it**. Tape brake on the current tune, then the next one starts.

Changed your mind? Press N / P again to arm another tune, or click the current one to cancel.

Stopped, N / P simply load the tune, at the top, ready to play.

## See the end coming

- The **time left** shows next to the clock.
- The **waveform turns orange** in the last 30 seconds: time to arm the next tune.
- Next to each strip's meter, a thin grey bar shows what its stems are playing **before** the fader and the mute. Vocal muted, you still see when the singer comes in, to open on time.

## A request in the middle of the set

The **+** at the top of the setlist opens the library with a search. The song you pick goes in just after the one playing, without touching the music.

Reorder on the fly with a right-click (Move up / Move down) or by dragging.

A tune played for 30 seconds or more is greyed with a ✓, still clickable. This mark is forgotten when the app quits; nothing is written in the setlist.

## Nothing cuts by mistake

While playing, anything that would stop the engine or leave a gap is refused, with a word in the top bar:

- loading or removing a plugin;
- putting a stem on a strip, or taking one off.

And also:

- A plain click on the waveform does not jump; double-click or ⌥-click does.
- Quitting, closing the window, NEW or opening another project ask first.
- Switching plate ↔ spring or phaser ↔ flanger happens without a gap: the new effect takes over, the old one rings out its tail.
- Re-patching the buses (the **Send to** menus) is live too.
- The screen stays on while playing, even when you only touch the console.

One exception: going to a tune whose insert plugin differs on a strip cuts the effect tails for a moment. The armed tune warns you. The same plugin on the same strip in both tunes stays plugged in.

## When it goes wrong

- **An echo howls**: <kbd>Esc</kbd>, or BANK LEFT + BANK RIGHT on the console. PANIC empties all the effects, the tune plays on.
- **The output clips**: keep **LIMITER ON** under the master fader.
- **Crackles**: see [Settings and help](../settings/#crackles-or-dropouts).
