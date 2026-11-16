# DubStemMix for the desktop (Linux, then Windows)

The third DubStemMix app, next to the Mac app and the MPC plugin. Product framing: `PRD.md` § 17. **Work in progress, not released.** Where each feature stands: `FEATURES.md`.

Built with [JUCE](https://juce.com). **This folder is distributed under the AGPLv3** (`desktop/LICENSE`); the rest of the repository (Mac app, MPC plugin, effects) stays under MIT.

## Where it stands: milestone L1, the JUCE base

For now the engine is the MPC plugin's (`mpc/DubStemMix/src`, compiled in unchanged, with the effects of `Sources/DubDSP`); JUCE gives it a sound card, the MIDImix and a plain window.

- Plays the songs of an **Export to MPC** folder (File ▸ Export Setlist to MPC… in the Mac app, to a folder), or the repository's test songs (`mpc/DubStemMix/Content/Songs`) when started from the repository with no argument.
- **MIDImix**, factory mapping, exactly as on the MPC: pages, effects and gestures come with the engine. Plugged or unplugged while running. Its LEDs are lit (MUTE, REC ARM, BANK).
- **Keyboard**: Space = play / pause, N = next song.
- **Window**: 8 strips (name, fader, meter, MUTE and REC ARM lamps) and the master, the song and time left, the sound card's buffer and rate, the MIDImix's state, the load, late buffers and disk dropouts. `Sound card...` picks the card and the buffer size.
- The engine runs at 44.1 kHz; a sound card at another rate is resampled to.

Next milestones (PRD § 17.5): projects as on the Mac, the console in the Mac's look, setlists, recording, third-party plugins, stem separation.

## Build and run

```sh
desktop/build.sh                                        # -> desktop/build/dubstemmix-desktop
desktop/build/dubstemmix-desktop                        # the repository's test songs
desktop/build/dubstemmix-desktop "/path/to/an export"   # an Export to MPC folder, or a card
desktop/build/dubstemmix-desktop --selftest             # no display, no sound card: checks the levels
```

- **macOS**: Xcode command line tools and CMake (`brew install cmake`).
- **Linux** (Ubuntu): `sudo apt install build-essential cmake git pkg-config libasound2-dev libfreetype-dev libfontconfig1-dev libx11-dev libxcomposite-dev libxcursor-dev libxext-dev libxinerama-dev libxrandr-dev libxrender-dev libglu1-mesa-dev mesa-common-dev`

The first build downloads JUCE and Akai's MPC Plugin SDK headers (the engine is written against them), both pinned. It takes a few minutes.

## Tested, not tested

- `--selftest` plays the same gestures, and expects the same levels, as the MPC plugin's own test (`mpc/tests/transport_test.cpp`). It runs in CI on Linux.
- Not tried on Linux yet: the MIDImix and its LEDs, and sound on a real PC.
- Windows: not built yet.
