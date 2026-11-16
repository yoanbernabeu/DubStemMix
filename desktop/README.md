# DubStemMix for the desktop (Linux, then Windows)

The third DubStemMix app, next to the Mac app and the MPC plugin. Product framing: `PRD.md` § 17. **Work in progress, not released.** Where each feature stands: `FEATURES.md`.

Built with [JUCE](https://juce.com). **This folder is distributed under the AGPLv3** (`desktop/LICENSE`); the rest of the repository (Mac app, MPC plugin, effects) stays under MIT.

## Where it stands: the console in the Mac's look, on the MPC plugin's engine

Milestones L1 (the JUCE base) and L3 (the console's look) of PRD § 17.5. For now the engine is the MPC plugin's (`mpc/DubStemMix/src`, compiled in unchanged, with the effects of `Sources/DubDSP`), and the songs come from an **Export to MPC** folder (File ▸ Export Setlist to MPC… in the Mac app, to a folder), or from the repository's test songs (`mpc/DubStemMix/Content/Songs`) when started from the repository with no argument.

- **The console's screen, as on the Mac** (palette, Archivo and JetBrains Mono, knobs, faders, meters): strips 1-6 (stems, or the siren and the Syndrum), the effect strips 7-8, the master column, the three bus cards, the setlist, the status. The four pages (MIX, FX, MASTER, INSERTS).
- **Everything is playable with the mouse**: knobs (drag up and down), faders, MUTE, THROW (held), KEEP, SOLO (the SOLO button, then MUTE), the pages, DROP / REWIND / HOLD / CRASH, the insert of each strip, the reverb and bus 3 models, delay sync, the throw target, where each bus is sent, the siren's wave and the Syndrum's roll. Touch a song in the setlist to play it next.
- **MIDImix**, factory mapping, exactly as on the MPC. Plugged or unplugged while running. Its LEDs are lit (MUTE, REC ARM, BANK).
- **Keyboard**: Space play / pause, N next song, D drop (held), H hold (held), C crash, R rewind, Esc panic.
- **The song's waveform** with its playhead (the last 30 s in ochre), and **cables between the bus cards** for bus-to-bus sends (dashed while the send knob is at zero).
- `SOUND CARD…` picks the card and the buffer size. The engine runs at 44.1 kHz; a sound card at another rate is resampled to.

Not there yet (they need the app's own engine, milestone L2): projects and stems dropped on strips, moving in the song by clicking the waveform, the song's tempo, the master meter and limiter indicator. Then setlists, recording, third-party plugins, stem separation.

## Build and run

```sh
desktop/build.sh                                        # -> desktop/build/dubstemmix-desktop
desktop/build/dubstemmix-desktop                        # the repository's test songs
desktop/build/dubstemmix-desktop "/path/to/an export"   # an Export to MPC folder, or a card
desktop/build/dubstemmix-desktop --selftest             # no display, no sound card: checks the levels
desktop/build/dubstemmix-desktop --snapshot out.png fx  # draws a page (mix, fx, master, inserts) to a picture
```

- **macOS**: Xcode command line tools and CMake (`brew install cmake`).
- **Linux** (Ubuntu): `sudo apt install build-essential cmake git pkg-config libasound2-dev libfreetype-dev libfontconfig1-dev libx11-dev libxcomposite-dev libxcursor-dev libxext-dev libxinerama-dev libxrandr-dev libxrender-dev libglu1-mesa-dev mesa-common-dev`

The first build downloads JUCE and Akai's MPC Plugin SDK headers (the engine is written against them), both pinned. It takes a few minutes.

## Tested, not tested

- `--selftest` plays the same gestures, and expects the same levels, as the MPC plugin's own test (`mpc/tests/transport_test.cpp`). It runs in CI on Linux.
- Not tried on Linux yet: the MIDImix and its LEDs, and sound on a real PC.
- Windows: not built yet.
