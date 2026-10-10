---
title: The effects and how to patch them
seoTitle: Dub delay, spring reverb, phaser, master chain · DubStemMix
description: "DubStemMix's built-in effects: tape echo, plate and spring reverb, Bi-Phase phaser, King Tubby's big knob, kills. Patch the buses, add Audio Units."
nav: The effects
order: 6
---

Everything here is built in: a full dub sound with no plugin at all. Three effects sit on **send buses** shared by all the strips, a chain of effects sits on the **master**, and each strip can hold an **insert**.

## The three effect cards

At the top of the window, one card per bus: **DELAY**, **REVERB** and **bus 3**. Each card shows its main settings and lights up in its colour while its effect sounds, tails included.

![The DELAY and REVERB cards, with the delay patched into the reverb](../../assets/screenshots/buses.png)

The name of the effect on each card is a menu: pick the built-in effect, or an Audio Unit plugin.

## The dub delay

A tape echo. Every repeat, the first one included, goes through the filters and the tape saturation, so the repeats get darker and rounder as they fade.

- **Time**: in milliseconds, or locked to the tempo with **SYNC** (1/16 to 1/2, dotted 1/8 and dotted 1/4 included). Changing it while echoes run bends their pitch, like a tape.
- **Feedback**: how many repeats. Up to self-oscillation: the echo feeds itself and howls, held by the tape.
- **Wow and flutter**: the tape wobbles.
- **Low cut, high cut**: filters inside the loop.
- **Heads** (MASTER page): the head patterns of a Space Echo, 1, 2, 3, 1+2, 2+3, 1+3, 1+2+3.
- **Ping-pong** (MASTER page): the repeats bounce between left and right.

## The reverb: plate or spring

Choose the model in the menu of the REVERB card.

- **Plate**: a smooth, dense plate.
- **Spring**: the reggae spring tank. A hit comes out as a falling *boing*. Only the spring can be crashed (<kbd>C</kbd>).

Settings on the FX page: decay, damping, predelay, low cut, tone.

## Bus 3: phaser or flanger

- **Phaser**: the big Bi-Phase phaser of 70s reggae, two phasers in series, deep and resonant. Settings: rate, depth, resonance, center, stereo.
- **Flanger**: a tape flanger, same knobs.

Both give only the shifted sound. Mixed with the strip's own sound, they carve the swirl: send a strip into bus 3 and turn the return up.

Bus 3 takes the name of its effect everywhere on screen: PHASER, FLANGER, or FX 3 with a plugin.

## The master chain

On the **MASTER** page, in the order of the sound:

- **Big knob**: King Tubby's high-pass filter from his MCI board. Twelve steps, from off (20 Hz) to 10 kHz: 70, 100, 150, 200, 300, 500, 800 Hz, 1, 2, 5, 10 kHz. Each step is a plateau you hear. Turn it up to thin the whole mix out, snap it back to OFF for the drop.
- **Kills**: the isolator of a sound-system preamp. Three knobs, **BASS**, **MID**, **TOP** (split at 200 Hz and 2.5 kHz). They only cut, never boost. All three up, the sound is untouched.
- **Dubplate**: the sound of an acetate played a hundred times. Narrower, saturated, slightly wobbly. A second knob adds **crackle**.
- **Pull-up**: the rewind gesture (<kbd>R</kbd>), on the whole master.

Each stage does nothing until you touch it.

## Strip inserts

Each stem strip can hold one effect between its stems and its fader. Choose it from the strip's **Insert** menu, play it on the **INSERTS** page.

- **Sub**: adds the octave below, following the bass. The "boom box" of the sound systems.
- **Auto-wah**: a Mu-Tron III style envelope filter. Play louder, the filter opens (or closes, in down mode). Made for the skank.
- **Any Audio Unit effect**: a compressor on the bass, a filter on the keys.

A plugin in an insert sits in the direct path of the strip: set its mix as you like.

## Patching the buses

On a dub board, you patch a return into a send and the effects start feeding each other. Here, each bus can also feed **one other bus**:

- **Delay into the reverb**: each repeat a little further away.
- **Delay into the phaser or the flanger**: the repeats start to turn.
- **Delay into a filter plugin on bus 3**: a filtered echo.

How:

1. On the card of the source bus, open **Send to** and pick the target.
2. Turn the matching knob up: strip 8 of the FX page (**DLY→**, **REV→** and the bus 3 one). The delay and reverb ones are also on strip 8 of the MIX page.

A cable then runs between the two cards, dashed while its knob is at zero, with the signal travelling along it. Chains work (delay → phaser → reverb). A target that would close a loop is greyed out, so effects can never feed back into each other without end.

Out of the box, no bus feeds another: each one only goes to the master.

## Before or after the fader

By default the sends are taken **after** the fader: pull the fader down, the send goes down with it. In Settings (⌘,), switch a bus to **before** the fader (pre-fader) for the classic move: the fader goes down, the strip still feeds its echo.

## Audio Unit plugins

Any Audio Unit effect installed on the Mac can replace a built-in effect on a bus, or sit in a strip's insert.

- **On a bus**, set the plugin **100 % wet**: the dry sound already reaches the master through the strip.
- **Open plugin window** on the card opens its interface.
- On the FX page, the bus's six knobs become **macros**: under each knob, pick the plugin parameter it drives. These choices are remembered per plugin, in every tune.
- Plugins run in a separate process: one that crashes falls back to the built-in effect, and stays in the project to be reloaded.
- A plugin missing on this Mac: the built-in effect stands in, a warning shows, and the plugin stays in the project for the Mac that has it.

Loading or removing a plugin is refused while playing (a notice says so): it would cut the sound for a fraction of a second, so stop playback first. Plugin latency is not compensated: fine on a bus, audible in an insert with a plugin that adds latency.
